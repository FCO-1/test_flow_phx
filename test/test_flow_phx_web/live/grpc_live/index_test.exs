defmodule TestFlowPhxWeb.GrpcLive.IndexTest do
  use TestFlowPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TestFlowPhx.Domain.Grpc.Response
  alias TestFlowPhx.Support.FakeGrpcExecutor
  alias TestFlowPhx.UseCases.Grpc.ProtoLoader

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

  defp load_echo_proto(view) do
    proto = file_input(view, "#proto-form", :protos, [%{name: "echo.proto", content: @proto, type: "text/plain"}])
    render_upload(proto, "echo.proto")
    view |> element("#proto-form") |> render_submit()
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

  describe "streaming en vivo + cancel" do
    test "muestra 'streaming…' con los mensajes mientras está en vuelo", %{conn: conn} do
      FakeGrpcExecutor.gate(self())
      FakeGrpcExecutor.stage(%Response{status: 0, streaming?: true, messages: [%{"n" => 1}, %{"n" => 2}]})

      {:ok, view, _html} = live(conn, "/grpc")
      load_echo_proto(view)
      view |> form("#grpc-form", request: %{method: "Down"}) |> render_submit()

      # el fake replicó los mensajes y quedó bloqueado: estado in-flight observable
      assert_receive {:fake_grpc_blocking, _task}, 1_000
      html = render(view)
      assert html =~ "streaming…"
      assert html =~ "&quot;n&quot;: 1"
      assert html =~ "&quot;n&quot;: 2"
    end

    test "Cancel detiene el stream y muestra 'cancelado'", %{conn: conn} do
      FakeGrpcExecutor.gate(self())
      FakeGrpcExecutor.stage(%Response{status: 0, streaming?: true, messages: [%{"n" => 1}]})

      {:ok, view, _html} = live(conn, "/grpc")
      load_echo_proto(view)
      view |> form("#grpc-form", request: %{method: "Down"}) |> render_submit()

      assert_receive {:fake_grpc_blocking, _task}, 1_000
      html = view |> element("button", "Cancel") |> render_click()
      assert html =~ "cancelado"
    end
  end

  describe "carga de .proto" do
    test "sube un .proto y puebla los dropdowns de service/method", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")
      html = load_echo_proto(view)

      assert html =~ "echo.Echoer"
      assert html =~ "Echo"
      assert html =~ "Down (stream)"
      assert html =~ "Cargado: echo.proto"
    end
  end
end
