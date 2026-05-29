defmodule TestFlowPhxWeb.GrpcLive.IndexTest do
  use TestFlowPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TestFlowPhx.Domain.Grpc.Response
  alias TestFlowPhx.Support.FakeGrpcExecutor
  alias TestFlowPhx.UseCases.Grpc.ProtoLoader

  setup do
    FakeGrpcExecutor.reset()
    ProtoLoader.clear_cache()
    on_exit(&FakeGrpcExecutor.reset/0)
    :ok
  end

  defp await(view) do
    Process.sleep(50)
    render(view)
  end

  describe "mount" do
    test "renderiza la nav de protocolos y el estado vacío", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/grpc")

      assert html =~ "gRPC"
      assert html =~ "REST"
      assert html =~ "cargá un .proto"
      assert html =~ "Sin respuesta todavía."
    end
  end

  describe "send → response (vía fake)" do
    test "unary: muestra grpc-status y el body decodificado", %{conn: conn} do
      FakeGrpcExecutor.stage(%Response{status: 0, body_decoded: %{"reply" => "hola"}, duration_ms: 3})

      {:ok, view, _html} = live(conn, "/grpc")

      view
      |> form("#grpc-form", request: %{target: "localhost:50051", body_text: ~s({"msg":"hi"})})
      |> render_submit()

      html = await(view)
      assert html =~ "grpc-status 0"
      assert html =~ "reply"
      assert html =~ "hola"
    end

    test "streaming: lista los mensajes acumulados", %{conn: conn} do
      FakeGrpcExecutor.stage(%Response{
        status: 0,
        streaming?: true,
        messages: [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}],
        duration_ms: 7
      })

      {:ok, view, _html} = live(conn, "/grpc")

      view |> form("#grpc-form", request: %{target: "localhost:50051"}) |> render_submit()

      html = await(view)
      assert html =~ "3 mensaje(s)"
      assert html =~ "&quot;n&quot;: 1"
      assert html =~ "&quot;n&quot;: 3"
    end

    test "error: muestra el panel de error con tipo y mensaje", %{conn: conn} do
      FakeGrpcExecutor.stage(%Response{
        status: 5,
        message: "not found",
        error: %{type: :grpc, code: 5, message: "no existe"}
      })

      {:ok, view, _html} = live(conn, "/grpc")

      view |> form("#grpc-form", request: %{target: "localhost:50051"}) |> render_submit()

      html = await(view)
      assert html =~ "grpc"
      assert html =~ "no existe"
    end
  end

  describe "carga de .proto" do
    @proto """
    syntax = "proto3";
    package echo;
    message Req { string msg = 1; }
    message Resp { string reply = 1; }
    service Echoer {
      rpc Echo(Req) returns (Resp);
      rpc Down(Req) returns (stream Resp);
    }
    """

    test "sube un .proto y puebla los dropdowns de service/method", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      proto =
        file_input(view, "#proto-form", :protos, [
          %{name: "echo.proto", content: @proto, type: "text/plain"}
        ])

      render_upload(proto, "echo.proto")
      html = view |> element("#proto-form") |> render_submit()

      assert html =~ "echo.Echoer"
      assert html =~ "Echo"
      assert html =~ "Down (stream)"
      assert html =~ "Cargado: echo.proto"
    end
  end
end
