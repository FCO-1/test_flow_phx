defmodule TestFlowPhxWeb.GrpcLive.IndexTest do
  use TestFlowPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TestFlowPhx.Domain.Grpc.Response
  alias TestFlowPhx.Infrastructure.Storage.{GrpcJsonFileRepo, JsonFileRepo}
  alias TestFlowPhx.Support.FakeGrpcExecutor
  alias TestFlowPhx.UseCases.Globals
  alias TestFlowPhx.UseCases.Grpc.{GrpcCollections, GrpcTabs, ProtoLoader}

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

  describe "tabs" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tf_grpc_tabs_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      start_supervised!(
        {GrpcJsonFileRepo,
         name: GrpcJsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 10}
      )

      :ok
    end

    test "abre con una tab Untitled y permite crear más", %{conn: conn} do
      {:ok, view, html} = live(conn, "/grpc")
      assert html =~ "Untitled"

      html = view |> element("button[aria-label='New tab']") |> render_click()
      # dos tabs Untitled ahora
      assert html |> String.split("Untitled") |> length() >= 3
    end

    test "cada tab tiene su propio request; cambiar de tab restaura su contenido",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      # tab 1: setea un target
      view |> form("#grpc-form", request: %{target: "uno:1111"}) |> render_change()
      [tab1] = GrpcTabs.list()

      # nueva tab (tab 2) con otro target
      view |> element("button[aria-label='New tab']") |> render_click()
      view |> form("#grpc-form", request: %{target: "dos:2222"}) |> render_change()

      tabs = GrpcTabs.list()
      assert length(tabs) == 2
      assert Enum.map(tabs, & &1.target) == ["uno:1111", "dos:2222"]

      # volver a la primera tab restaura su target
      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-id='#{tab1.id}']")
        |> render_click()

      assert html =~ "uno:1111"
    end

    test "cerrar la última tab siembra una fresca", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")
      view |> form("#grpc-form", request: %{target: "x:1"}) |> render_change()
      [tab] = GrpcTabs.list()

      view
      |> element("button[phx-click='close_tab'][phx-value-id='#{tab.id}']")
      |> render_click()

      tabs = GrpcTabs.list()
      assert length(tabs) == 1
      assert hd(tabs).id != tab.id
    end

    test "las tabs persisten entre reloads del navegador", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")
      view |> form("#grpc-form", request: %{target: "persistido:1"}) |> render_change()
      view |> element("button[aria-label='New tab']") |> render_click()
      view |> form("#grpc-form", request: %{target: "persistido:2"}) |> render_change()

      # nuevo mount = nuevo "reload": restaura las dos tabs
      {:ok, _view2, html2} = live(conn, "/grpc")
      assert html2 =~ "persistido:2"
      assert length(GrpcTabs.list()) == 2
    end

    test "el response queda aislado por tab", %{conn: conn} do
      FakeGrpcExecutor.stage(%Response{status: 0, body_decoded: %{"reply" => "tab-uno"}, duration_ms: 1})

      {:ok, view, _html} = live(conn, "/grpc")
      view |> form("#grpc-form", request: %{target: "localhost:50051"}) |> render_change()
      [tab1] = GrpcTabs.list()

      view |> form("#grpc-form", request: %{target: "localhost:50051"}) |> render_submit()
      assert await(view) =~ "tab-uno"

      # nueva tab: sin respuesta todavía
      html = view |> element("button[aria-label='New tab']") |> render_click()
      assert html =~ "Sin respuesta todavía."

      # volver a la tab 1 muestra de nuevo su respuesta
      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-id='#{tab1.id}']")
        |> render_click()

      assert html =~ "tab-uno"
    end
  end

  describe "export / import nativo" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tf_grpc_exim_lv_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      start_supervised!(
        {GrpcJsonFileRepo,
         name: GrpcJsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 10}
      )

      :ok
    end

    test "Export dispara la descarga del JSON de la colección", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")
      view |> form("form[phx-submit='new_collection']", %{name: "Exportable"}) |> render_submit()
      [coll] = GrpcCollections.list()

      view
      |> element("button[phx-click='export_grpc_collection'][phx-value-id='#{coll.id}']")
      |> render_click()

      assert_push_event(view, "download:file", %{content: content, filename: filename})
      assert filename =~ ".json"
      assert {:ok, %{"format" => "testflow-grpc-collection"}} = Jason.decode(content)
    end

    test "Import carga colecciones desde un JSON nativo", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      json =
        ~s({"format":"testflow-grpc-collection","version":1,"collections":[{"name":"Importada","requests":[{"name":"r","target":"h:1","method":"Echo"}]}]})

      render_hook(view, "import:file", %{"content" => json})

      assert [%{name: "Importada", requests: [%{method: "Echo"}]}] = GrpcCollections.list()
      assert render(view) =~ "Importada"
    end

    test "Import de JSON inválido muestra error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")
      html = render_hook(view, "import:file", %{"content" => "no es json"})
      assert html =~ "no es JSON válido"
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
