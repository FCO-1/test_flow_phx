defmodule TestFlowPhxWeb.GrpcLive.IndexTest do
  use TestFlowPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TestFlowPhx.Domain.Grpc.Response
  alias TestFlowPhx.Infrastructure.Storage.{GrpcJsonFileRepo, JsonFileRepo}
  alias TestFlowPhx.Support.FakeGrpcExecutor
  alias TestFlowPhx.UseCases.Globals
  alias TestFlowPhx.UseCases.Grpc.{GrpcCollections, ProtoLoader}

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

  describe "variables {{var}}" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tf_grpc_vars_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      start_supervised!({JsonFileRepo, name: JsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 10})
      :ok
    end

    test "resuelve {{var}} (globals) en target y body antes de enviar; muestra el hint", %{conn: conn} do
      Globals.replace([
        %{name: "host", value: "1.2.3.4:9000", enabled: true},
        %{name: "user_id", value: "ada", enabled: true}
      ])

      FakeGrpcExecutor.stage(%Response{status: 0})

      {:ok, view, html} = live(conn, "/grpc")
      assert html =~ "{{host}}"

      view
      |> form("#grpc-form", request: %{target: "{{host}}", body_text: ~s({"id":"{{user_id}}"})})
      |> render_submit()

      await(view)

      captured = FakeGrpcExecutor.last_request()
      assert captured.target == "1.2.3.4:9000"
      assert captured.body_text == ~s({"id":"ada"})
    end
  end

  describe "colecciones" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tf_grpc_coll_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      start_supervised!(
        {GrpcJsonFileRepo,
         name: GrpcJsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 10}
      )

      :ok
    end

    test "crea una colección desde el sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      html =
        view
        |> form("form[phx-submit='new_collection']", %{name: "Mi colección"})
        |> render_submit()

      assert html =~ "Mi colección"
      assert [%{name: "Mi colección"}] = GrpcCollections.list()
    end

    test "guarda el request actual y lo reabre en el form", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      view |> form("form[phx-submit='new_collection']", %{name: "C"}) |> render_submit()
      [coll] = GrpcCollections.list()

      view
      |> form("#grpc-form", request: %{target: "saved-host:1234", body_text: ~s({"a":1})})
      |> render_change()

      view
      |> form("form[phx-submit='save_to_collection']", %{collection_id: coll.id, name: "Echo guardado"})
      |> render_submit()

      # el request quedó guardado en la colección
      assert [stored] = GrpcCollections.list()
      assert [%{name: "Echo guardado", target: "saved-host:1234"}] = stored.requests

      # expandir la colección lo muestra
      html =
        view
        |> element("button[phx-click='toggle_collection'][phx-value-id='#{coll.id}']")
        |> render_click()

      assert html =~ "Echo guardado"

      # cambiar el target y reabrir el guardado lo restaura
      view |> form("#grpc-form", request: %{target: "otro:9999"}) |> render_change()

      html = view |> element("button[phx-click='open_grpc_request']") |> render_click()
      assert html =~ "saved-host:1234"
    end

    test "las collection-vars resuelven {{var}} al enviar", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      view |> form("form[phx-submit='new_collection']", %{name: "C"}) |> render_submit()
      [coll] = GrpcCollections.list()
      :ok = GrpcCollections.set_variables(coll.id, [%{name: "host", value: "9.9.9.9:1", enabled: true}])

      # guardar el request en la colección: a partir de acá pertenece a ella
      view |> form("#grpc-form", request: %{target: "{{host}}"}) |> render_change()

      view
      |> form("form[phx-submit='save_to_collection']", %{collection_id: coll.id, name: "R"})
      |> render_submit()

      FakeGrpcExecutor.stage(%Response{status: 0})
      view |> form("#grpc-form", request: %{target: "{{host}}"}) |> render_submit()
      await(view)

      assert FakeGrpcExecutor.last_request().target == "9.9.9.9:1"
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
