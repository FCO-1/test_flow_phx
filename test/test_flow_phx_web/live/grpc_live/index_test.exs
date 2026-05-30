defmodule TestFlowPhxWeb.GrpcLive.IndexTest do
  use TestFlowPhxWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias TestFlowPhx.Domain.Grpc.Response
  alias TestFlowPhx.Infrastructure.Storage.{GrpcJsonFileRepo, JsonFileRepo, Paths}
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
    File.rm_rf(Paths.proto_sets_dir())
    on_exit(fn ->
      FakeGrpcExecutor.reset()
      File.rm_rf(Paths.proto_sets_dir())
    end)

    :ok
  end

  defp await(view) do
    Process.sleep(50)
    render(view)
  end

  defp load_echo_proto(view) do
    proto =
      file_input(view, "#proto-form", :protos, [
        %{name: "echo.proto", content: @proto, type: "text/plain"}
      ])

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

  describe "proto-sets (upload .zip con imports)" do
    @dep """
    syntax = "proto3";
    package donavida.comun.v1;
    message C { string x = 1; }
    """

    @auth """
    syntax = "proto3";
    package donavida.auth.v1;
    import "donavida/comun/v1/c.proto";
    message Req { donavida.comun.v1.C c = 1; }
    message Resp { string ok = 1; }
    service Svc { rpc Call(Req) returns (Resp); }
    """

    defp zip(files) do
      entries = Enum.map(files, fn {n, c} -> {String.to_charlist(n), c} end)
      {:ok, {_n, bin}} = :zip.create(~c"set.zip", entries, [:memory])
      bin
    end

    test "subir un .zip con imports crea el proto-set y puebla service/method", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      bin =
        zip([
          {"donavida/auth/v1/auth.proto", @auth},
          {"donavida/comun/v1/c.proto", @dep}
        ])

      up = file_input(view, "#proto-form", :protos, [%{name: "donavida.zip", content: bin}])
      render_upload(up, "donavida.zip")
      html = view |> element("#proto-form") |> render_submit()

      # el service del .proto con imports quedó disponible y preseleccionado
      assert html =~ "donavida.auth.v1.Svc"
      assert html =~ "Call"
      # y el proto-set aparece en el selector
      assert html =~ "donavida"
    end
  end

  describe "send → response (vía fake)" do
    test "unary: muestra grpc-status y el body decodificado", %{conn: conn} do
      FakeGrpcExecutor.stage(%Response{
        status: 0,
        body_decoded: %{"reply" => "hola"},
        duration_ms: 3
      })

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

      FakeGrpcExecutor.stage(%Response{
        status: 0,
        streaming?: true,
        messages: [%{"n" => 1}, %{"n" => 2}]
      })

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
      html = view |> element("button[phx-click='cancel']") |> render_click()
      assert html =~ "cancelado"
    end
  end

  describe "variables {{var}}" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tf_grpc_vars_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      start_supervised!(
        {JsonFileRepo, name: JsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 10}
      )

      :ok
    end

    test "resuelve {{var}} (globals) en target y body antes de enviar; muestra el hint", %{
      conn: conn
    } do
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
      |> form("form[phx-submit='save_to_collection']", %{
        collection_id: coll.id,
        name: "Echo guardado"
      })
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

      :ok =
        GrpcCollections.set_variables(coll.id, [
          %{name: "host", value: "9.9.9.9:1", enabled: true}
        ])

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

      html = view |> element("button[phx-click='new_tab']") |> render_click()
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
      view |> element("button[phx-click='new_tab']") |> render_click()
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
      view |> element("button[phx-click='new_tab']") |> render_click()
      view |> form("#grpc-form", request: %{target: "persistido:2"}) |> render_change()

      # nuevo mount = nuevo "reload": restaura las dos tabs
      {:ok, _view2, html2} = live(conn, "/grpc")
      assert html2 =~ "persistido:2"
      assert length(GrpcTabs.list()) == 2
    end

    test "el response queda aislado por tab", %{conn: conn} do
      FakeGrpcExecutor.stage(%Response{
        status: 0,
        body_decoded: %{"reply" => "tab-uno"},
        duration_ms: 1
      })

      {:ok, view, _html} = live(conn, "/grpc")
      view |> form("#grpc-form", request: %{target: "localhost:50051"}) |> render_change()
      [tab1] = GrpcTabs.list()

      view |> form("#grpc-form", request: %{target: "localhost:50051"}) |> render_submit()
      assert await(view) =~ "tab-uno"

      # nueva tab: sin respuesta todavía
      html = view |> element("button[phx-click='new_tab']") |> render_click()
      assert html =~ "Sin respuesta todavía."

      # volver a la tab 1 muestra de nuevo su respuesta
      html =
        view
        |> element("button[phx-click='select_tab'][phx-value-id='#{tab1.id}']")
        |> render_click()

      assert html =~ "tab-uno"
    end

    test "Guardar todas las tabs crea una colección con un request por tab",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      # arranca con 1 tab; abrir una segunda
      view |> element("button[phx-click='new_tab']") |> render_click()
      assert length(GrpcTabs.list()) == 2

      # volcar todas a una colección nueva
      view
      |> form("form[phx-submit='save_all_tabs']", %{name: "Mis tabs"})
      |> render_submit()

      assert [%{name: "Mis tabs", requests: reqs}] = GrpcCollections.list()
      assert length(reqs) == 2
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

    test "Import auto-expande la colección y abrir requests crea tabs nuevas",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      json =
        ~s({"format":"testflow-grpc-collection","version":1,"collections":[{"name":"Suite","requests":[) <>
          ~s({"name":"Req Uno","target":"h:1","method":"Echo"},) <>
          ~s({"name":"Req Dos","target":"h:2","method":"Echo"}]}]})

      # Tras importar, la colección queda desplegada: sus requests se ven sin
      # tener que hacer click en el toggle.
      html = render_hook(view, "import:file", %{"content" => json})
      assert html =~ "Req Uno"
      assert html =~ "Req Dos"

      [coll] = GrpcCollections.list()
      [r1, r2] = coll.requests

      # Abrir cada request lo lleva a una TAB NUEVA (no pisa la activa): la tab
      # sembrada + las dos abiertas = 3.
      view
      |> element("button[phx-click='open_grpc_request'][phx-value-request-id='#{r1.id}']")
      |> render_click()

      assert length(GrpcTabs.list()) == 2

      html =
        view
        |> element("button[phx-click='open_grpc_request'][phx-value-request-id='#{r2.id}']")
        |> render_click()

      assert length(GrpcTabs.list()) == 3
      # la tab activa es la del último request abierto
      assert html =~ "h:2"
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

  describe "variables UI (sidebar globals + modal de colección)" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "tf_grpc_varsui_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      # JsonFileRepo: globals (transversal). GrpcJsonFileRepo: colecciones/tabs.
      start_supervised!(
        {JsonFileRepo, name: JsonFileRepo, path: Path.join(tmp, "rest.json"), flush_after_ms: 10}
      )

      start_supervised!(
        {GrpcJsonFileRepo,
         name: GrpcJsonFileRepo, path: Path.join(tmp, "grpc.json"), flush_after_ms: 10}
      )

      :ok
    end

    test "editar un global desde la sección Variables persiste y resuelve {{var}} al enviar",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      # cambiar a la sección Variables y agregar una fila de global
      view
      |> element("button[phx-click='sidebar_section'][phx-value-section='variables']")
      |> render_click()

      view |> element("button[phx-click='add_global_row']") |> render_click()

      # llenar la fila (update_globals)
      view
      |> form("form[phx-change='update_globals']", %{
        "globals" => %{"0" => %{"name" => "host", "value" => "9.9.9.9:1", "enabled" => "true"}}
      })
      |> render_change()

      assert [%{name: "host", value: "9.9.9.9:1", enabled: true}] = Globals.list()

      # y resuelve {{host}} al enviar
      FakeGrpcExecutor.stage(%Response{status: 0})
      view |> form("#grpc-form", request: %{target: "{{host}}"}) |> render_submit()
      await(view)

      assert FakeGrpcExecutor.last_request().target == "9.9.9.9:1"
    end

    test "abrir el modal de vars de una colección y agregar una var la guarda",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/grpc")

      view |> form("form[phx-submit='new_collection']", %{name: "C"}) |> render_submit()
      [coll] = GrpcCollections.list()

      # abrir el modal de vars de esa colección
      view
      |> element("button[phx-click='open_collection_vars_modal'][phx-value-id='#{coll.id}']")
      |> render_click()

      # agregar una fila y llenarla
      view |> element("button[phx-click='add_collection_var_row']") |> render_click()

      view
      |> form("form[phx-change='update_collection_vars']", %{
        "collection_id" => coll.id,
        "vars" => %{"0" => %{"name" => "base", "value" => "x:1", "enabled" => "true"}}
      })
      |> render_change()

      assert [%{variables: [%{name: "base", value: "x:1", enabled: true}]}] =
               GrpcCollections.list()
    end
  end
end
