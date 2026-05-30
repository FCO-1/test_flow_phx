defmodule TestFlowPhxWeb.GrpcLive.Index do
  @moduledoc """
  LiveView del tester gRPC. Vive en su propia carpeta (`live/grpc_live/`),
  separada de `rest_live/`: el switch entre protocolos es por **router**
  (`~p"/"` ↔ `~p"/grpc"`), no por estado compartido.

  Flujo (N.8, básico, unary + streaming-no-vivo):

    1. El usuario sube un `.proto` o un `.zip` (árbol con imports) → se crea un
       **proto-set** (`GrpcProtoSets`: valida con protoc + autodetecta el import
       root) y se carga con `ProtoLoader`. También puede elegir un proto-set ya
       subido del selector.
    2. Elige service + method (dropdowns dependientes), llena target,
       metadata (kv) y body (JSON).
    3. Send → `UseCases.Grpc.SendGrpcRequest.execute/2` en un Task; el response
       se decodifica y se muestra (unary: body; streaming: lista de mensajes).

  Soporta múltiples tabs (N.11c): cada tab es un `Grpc.Request` persistido en
  `data/grpc/state.json` vía `TabState`/`GrpcTabs`. El estado runtime por tab
  (response, in-flight, streaming en vivo, cancelación, task) vive en mapas
  keyed por `tab_id`; `TabState.put_active_view/1` deriva la vista de la tab
  activa. La presentación nunca llama infraestructura directo: todo vía use cases.
  """

  use TestFlowPhxWeb, :live_view

  alias TestFlowPhx.Domain.Grpc.{Collection, Request, Response}
  alias TestFlowPhx.UseCases.{Globals, Settings, Translations, Variables}

  alias TestFlowPhx.Domain.Grpc.ProtoSet

  alias TestFlowPhx.UseCases.Grpc.{
    GrpcCollectionExport,
    GrpcCollectionImport,
    GrpcCollections,
    GrpcProtoSets,
    ProtoLoader,
    SendGrpcRequest
  }

  alias TestFlowPhxWeb.GrpcLive.{Format, Params, Proto, TabState}
  alias TestFlowPhxWeb.TesterComponents

  @impl true
  def mount(_params, _session, socket) do
    {tabs, active_id} = TabState.load_or_seed()

    socket =
      socket
      |> assign(:page_title, "TestFlow gRPC")
      |> assign(:locale, Settings.get_locale())
      |> assign(:tabs, tabs)
      |> assign(:active_tab_id, active_id)
      |> assign(:responses, %{})
      |> assign(:in_flight_tabs, MapSet.new())
      |> assign(:streaming_tabs, MapSet.new())
      |> assign(:cancelled_tabs, MapSet.new())
      |> assign(:stream_messages_by_tab, %{})
      |> assign(:send_refs, %{})
      |> assign(:send_tasks, %{})
      |> assign(:globals, load_globals())
      |> assign(:collections, load_collections())
      |> assign(:expanded_collections, MapSet.new())
      |> assign(:sidebar_section, :collections)
      |> assign(:collection_vars_modal, nil)
      |> assign(:proto, nil)
      |> assign(:proto_error, nil)
      |> assign(:proto_names, [])
      |> assign(:proto_sets, list_proto_sets())
      |> TabState.put_active_view()
      |> load_active_proto()
      |> allow_upload(:protos, accept: :any, max_entries: 1, auto_upload: false)

    {:ok, socket}
  end

  # ---------- Carga de .proto ----------

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  # Sube un `.proto` (autocontenido) o un `.zip` (árbol con imports) y lo
  # convierte en un proto-set (`GrpcProtoSets`): valida con protoc y autodetecta
  # el import root. El set queda activo en la tab.
  def handle_event("load_protos", _params, socket) do
    results =
      consume_uploaded_entries(socket, :protos, fn %{path: tmp}, entry ->
        {:ok, create_set_from_upload(tmp, entry.client_name)}
      end)

    socket =
      case results do
        [{:ok, %ProtoSet{} = set} | _] ->
          activate_set(socket, set)

        [{:error, msg} | _] ->
          assign(socket, proto: nil, proto_error: msg, proto_names: [])

        [] ->
          assign(socket, :proto_error, Translations.t(socket.assigns.locale, "grpc.no_proto_uploaded"))
      end

    {:noreply, socket}
  end

  # ---------- Selección de proto-set / archivo entry ----------

  def handle_event("select_proto_set", %{"proto_set_id" => ""}, socket) do
    socket =
      socket
      |> TabState.update_active(fn req -> %{req | proto_set_id: nil, entry_file: nil} end)
      |> TabState.put_active_view()
      |> reload_proto_assigns()
      |> TabState.save()

    {:noreply, socket}
  end

  def handle_event("select_proto_set", %{"proto_set_id" => id}, socket) do
    case GrpcProtoSets.get(id) do
      %ProtoSet{} = set -> {:noreply, activate_set(socket, set)}
      nil -> {:noreply, socket}
    end
  end

  def handle_event("select_entry_file", %{"entry_file" => entry}, socket) do
    socket =
      socket
      |> TabState.update_active(fn req -> %{req | entry_file: entry} end)
      |> TabState.put_active_view()
      |> reload_proto_assigns()
      |> preselect_active()
      |> TabState.save()

    {:noreply, socket}
  end

  # ---------- Tabs ----------

  def handle_event("select_tab", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.tabs, &(&1.id == id)) do
      socket =
        socket
        |> assign(:active_tab_id, id)
        |> TabState.put_active_view()
        |> load_active_proto()
        |> TabState.save()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_tab", _params, socket) do
    new_tab = TabState.new_request()

    socket =
      socket
      |> update(:tabs, &(&1 ++ [new_tab]))
      |> assign(:active_tab_id, new_tab.id)
      |> TabState.put_active_view()
      |> load_active_proto()
      |> TabState.save()

    {:noreply, socket}
  end

  def handle_event("close_tab", %{"id" => id}, socket) do
    tabs = socket.assigns.tabs

    case Enum.find_index(tabs, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      idx ->
        kill_task(socket, id)
        remaining = List.delete_at(tabs, idx)

        new_active_id =
          cond do
            socket.assigns.active_tab_id != id -> socket.assigns.active_tab_id
            remaining == [] -> nil
            true -> Enum.at(remaining, min(idx, length(remaining) - 1)).id
          end

        {tabs, active_id} =
          if remaining == [] do
            fresh = TabState.new_request()
            {[fresh], fresh.id}
          else
            {remaining, new_active_id}
          end

        socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:active_tab_id, active_id)
          |> TabState.clear_runtime(id)
          |> update(:send_tasks, &Map.delete(&1, id))
          |> TabState.drop_send_refs_for(id)
          |> TabState.put_active_view()
          |> load_active_proto()
          |> TabState.save()

        {:noreply, socket}
    end
  end

  # ---------- Edición del request ----------

  def handle_event("validate", %{"request" => params}, socket) do
    socket =
      socket
      |> TabState.update_active(fn req -> Params.apply(req, socket.assigns.proto, params) end)
      |> TabState.save()

    {:noreply, socket}
  end

  def handle_event("add_kv_row", %{"field" => "metadata"}, socket) do
    socket =
      socket
      |> TabState.update_active(fn req ->
        %{req | metadata: req.metadata ++ [Request.empty_kv()]}
      end)
      |> TabState.save()

    {:noreply, socket}
  end

  def handle_event("remove_kv_row", %{"field" => "metadata", "index" => idx}, socket) do
    socket =
      socket
      |> TabState.update_active(fn req ->
        %{req | metadata: List.delete_at(req.metadata, String.to_integer(idx))}
      end)
      |> TabState.save()

    {:noreply, socket}
  end

  # ---------- Colecciones ----------

  def handle_event("new_collection", %{"name" => name}, socket) do
    case String.trim(name) do
      "" ->
        {:noreply, socket}

      name ->
        try_call(fn -> GrpcCollections.create(name) end)
        {:noreply, refresh_collections(socket)}
    end
  end

  def handle_event("toggle_collection", %{"id" => id}, socket) do
    {:noreply, update(socket, :expanded_collections, &toggle(&1, id))}
  end

  def handle_event("delete_collection", %{"id" => id}, socket) do
    try_call(fn -> GrpcCollections.delete(id) end)
    {:noreply, refresh_collections(socket)}
  end

  # ---------- Export / Import (formato nativo gRPC) ----------

  def handle_event("export_grpc_collection", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.collections, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      coll ->
        {:noreply, download_json(socket, coll.name, GrpcCollectionExport.to_json(coll))}
    end
  end

  def handle_event("export_all_grpc_collections", _params, socket) do
    case socket.assigns.collections do
      [] -> {:noreply, socket}
      colls -> {:noreply, download_json(socket, nil, GrpcCollectionExport.to_json(colls))}
    end
  end

  def handle_event("import:file", %{"content" => content}, socket) do
    before_ids = MapSet.new(socket.assigns.collections, & &1.id)

    case GrpcCollectionImport.import_all(content) do
      {:ok, count} ->
        socket = refresh_collections(socket)

        # Auto-expande las colecciones recién importadas para que sus requests se
        # vean sin un click extra (el usuario las quiere desplegadas al cargar).
        new_ids =
          socket.assigns.collections
          |> Enum.map(& &1.id)
          |> Enum.reject(&MapSet.member?(before_ids, &1))

        socket =
          socket
          |> update(:expanded_collections, fn ex ->
            Enum.reduce(new_ids, ex, &MapSet.put(&2, &1))
          end)
          |> put_flash(:info, imported_flash(socket.assigns.locale, count))

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, GrpcCollectionImport.format_error(reason))}
    end
  end

  def handle_event("import:error", %{"message" => msg}, socket),
    do: {:noreply, put_flash(socket, :error, msg)}

  # ---------- Sidebar: secciones (Colecciones | Variables) ----------

  def handle_event("sidebar_section", %{"section" => section}, socket)
      when section in ["collections", "variables"] do
    {:noreply, assign(socket, :sidebar_section, String.to_existing_atom(section))}
  end

  # ---------- Globals (variables globales) ----------

  def handle_event("update_globals", %{"globals" => params}, socket) do
    vars = parse_globals_params(params)
    try_call(fn -> Globals.replace(vars) end)
    {:noreply, assign(socket, :globals, vars)}
  end

  def handle_event("update_globals", _params, socket), do: {:noreply, socket}

  def handle_event("add_global_row", _params, socket) do
    vars = socket.assigns.globals ++ [Variables.empty()]
    try_call(fn -> Globals.replace(vars) end)
    {:noreply, assign(socket, :globals, vars)}
  end

  def handle_event("remove_global_row", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)
    vars = List.delete_at(socket.assigns.globals, idx)
    try_call(fn -> Globals.replace(vars) end)
    {:noreply, assign(socket, :globals, vars)}
  end

  # ---------- Variables de colección (modal) ----------

  def handle_event("open_collection_vars_modal", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.collections, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      %Collection{} = c ->
        state = %{collection_id: c.id, collection_name: c.name, vars: c.variables}
        {:noreply, assign(socket, :collection_vars_modal, state)}
    end
  end

  def handle_event("close_collection_vars_modal", _params, socket),
    do: {:noreply, assign(socket, :collection_vars_modal, nil)}

  def handle_event("update_collection_vars", %{"collection_id" => coll_id} = params, socket) do
    vars = params |> Map.get("vars", %{}) |> parse_vars_params()
    persist_collection_vars(socket, coll_id, vars)
  end

  def handle_event("add_collection_var_row", _params, socket) do
    case socket.assigns.collection_vars_modal do
      nil ->
        {:noreply, socket}

      %{collection_id: coll_id, vars: vars} ->
        persist_collection_vars(socket, coll_id, vars ++ [Variables.empty()])
    end
  end

  def handle_event("remove_collection_var_row", %{"index" => idx_str}, socket) do
    case socket.assigns.collection_vars_modal do
      nil ->
        {:noreply, socket}

      %{collection_id: coll_id, vars: vars} ->
        idx = String.to_integer(idx_str)
        persist_collection_vars(socket, coll_id, List.delete_at(vars, idx))
    end
  end

  # Guarda el request actual en una colección. El nombre del form tiene
  # precedencia; si viene vacío cae al nombre del request en edición.
  def handle_event("save_to_collection", %{"collection_id" => cid} = params, socket) do
    case String.trim(cid) do
      "" ->
        {:noreply, socket}

      cid ->
        name = request_name(params["name"], socket.assigns.request.name)
        req = %{socket.assigns.request | name: name, collection_id: cid}

        # La tab activa siempre tiene id, así que add_request lo preserva: el
        # request guardado conserva el id de la tab → la actualizamos en sitio.
        socket =
          case try_call(fn -> GrpcCollections.add_request(cid, req) end) do
            %Request{} = saved ->
              socket
              |> TabState.update_active(fn _ -> saved end)
              |> TabState.save()

            _ ->
              socket
          end

        {:noreply, refresh_collections(socket)}
    end
  end

  # Abre un request guardado en una **tab nueva** (copia con id de tab fresco,
  # apilada al final y activada), espejo del `open_request_in_tab` de REST. Así se
  # pueden tener varios requests de la colección abiertos a la vez y correrlos sin
  # pisar la tab activa. La tab es una copia de trabajo; abrir el mismo request dos
  # veces da dos tabs. Recarga el descriptor desde el proto-set/paths para repoblar
  # los dropdowns; el contenido guardado (service/method) se preserva.
  def handle_event(
        "open_grpc_request",
        %{"collection-id" => cid, "request-id" => rid},
        socket
      ) do
    case find_request(socket.assigns.collections, cid, rid) do
      %Request{} = req ->
        tab = %{req | id: Request.new_id(), collection_id: cid}

        socket =
          socket
          |> update(:tabs, &(&1 ++ [tab]))
          |> assign(:active_tab_id, tab.id)
          |> TabState.put_active_view()
          |> load_active_proto()
          |> TabState.save()

        {:noreply, socket}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event(
        "delete_request_from_collection",
        %{"collection-id" => cid, "request-id" => rid},
        socket
      ) do
    try_call(fn -> GrpcCollections.remove_request(cid, rid) end)
    {:noreply, refresh_collections(socket)}
  end

  # ---------- Send ----------

  def handle_event("send", params, socket) do
    tab_id = socket.assigns.active_tab_id

    if MapSet.member?(socket.assigns.in_flight_tabs, tab_id) do
      {:noreply, socket}
    else
      socket =
        case params do
          %{"request" => form} ->
            TabState.update_active(socket, fn req ->
              Params.apply(req, socket.assigns.proto, form)
            end)

          _ ->
            socket
        end

      request = socket.assigns.request
      streaming? = Proto.streaming_method?(socket.assigns.proto, request.service, request.method)
      lv = self()

      # on_message empuja cada mensaje al LV en vivo (etiquetado con su tab); el
      # executor igual acumula todo en Response.messages para el resultado final.
      vars = active_vars(socket)

      task =
        Task.Supervisor.async_nolink(TestFlowPhx.TaskSupervisor, fn ->
          SendGrpcRequest.execute(request,
            vars: vars,
            on_message: fn msg -> Kernel.send(lv, {:grpc_msg, tab_id, msg}) end
          )
        end)

      streaming_op = if streaming?, do: &MapSet.put(&1, tab_id), else: &MapSet.delete(&1, tab_id)

      socket =
        socket
        |> update(:in_flight_tabs, &MapSet.put(&1, tab_id))
        |> update(:streaming_tabs, streaming_op)
        |> update(:cancelled_tabs, &MapSet.delete(&1, tab_id))
        |> update(:stream_messages_by_tab, &Map.put(&1, tab_id, []))
        |> update(:responses, &Map.put(&1, tab_id, nil))
        |> update(:send_refs, &Map.put(&1, task.ref, tab_id))
        |> update(:send_tasks, &Map.put(&1, tab_id, task))
        |> TabState.put_active_view()
        |> TabState.save()

      {:noreply, socket}
    end
  end

  # Cancela el stream en curso de la tab activa matando su Task: la conexión
  # HTTP/2 está linkeada al proceso del Task (Http2Client.connect/start_link),
  # así que muere con él (RST_STREAM). El {:DOWN} resultante se ignora porque la
  # tab queda marcada en cancelled_tabs.
  def handle_event("cancel", _params, socket) do
    tab_id = socket.assigns.active_tab_id

    case Map.get(socket.assigns.send_tasks, tab_id) do
      %Task{pid: pid} ->
        Task.Supervisor.terminate_child(TestFlowPhx.TaskSupervisor, pid)

        socket =
          socket
          |> update(:cancelled_tabs, &MapSet.put(&1, tab_id))
          |> update(:in_flight_tabs, &MapSet.delete(&1, tab_id))
          |> update(:streaming_tabs, &MapSet.delete(&1, tab_id))
          |> update(:send_tasks, &Map.delete(&1, tab_id))
          |> TabState.put_active_view()

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:grpc_msg, tab_id, msg}, socket) do
    socket =
      socket
      |> update(:stream_messages_by_tab, fn m -> Map.update(m, tab_id, [msg], &(&1 ++ [msg])) end)
      |> TabState.put_active_view()

    {:noreply, socket}
  end

  def handle_info({ref, %Response{} = response}, socket) when is_reference(ref) do
    case Map.fetch(socket.assigns.send_refs, ref) do
      {:ok, tab_id} ->
        Process.demonitor(ref, [:flush])

        socket =
          socket
          |> update(:responses, &Map.put(&1, tab_id, response))
          |> update(:in_flight_tabs, &MapSet.delete(&1, tab_id))
          |> update(:streaming_tabs, &MapSet.delete(&1, tab_id))
          |> update(:send_refs, &Map.delete(&1, ref))
          |> update(:send_tasks, &Map.delete(&1, tab_id))
          |> TabState.put_active_view()

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    case Map.fetch(socket.assigns.send_refs, ref) do
      {:ok, tab_id} ->
        socket =
          socket
          |> update(:in_flight_tabs, &MapSet.delete(&1, tab_id))
          |> update(:streaming_tabs, &MapSet.delete(&1, tab_id))
          |> update(:send_refs, &Map.delete(&1, ref))
          |> update(:send_tasks, &Map.delete(&1, tab_id))

        # Si fue cancelación del usuario, no es un error: la lista en vivo queda.
        socket =
          if MapSet.member?(socket.assigns.cancelled_tabs, tab_id) do
            socket
          else
            update(socket, :responses, fn m ->
              Map.put(m, tab_id, %Response{
                error: %{
                  type: :unknown,
                  message:
                    Translations.t(socket.assigns.locale, "grpc.flashes.send_failed",
                      reason: inspect(reason)
                    ),
                  code: nil
                }
              })
            end)
          end

        {:noreply, TabState.put_active_view(socket)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ---------- Variables ----------

  # Variables aplicables a este request: globals ∪ vars de la colección activa
  # (la del request en edición, vía collection_id). Precedencia: colección > global.
  defp active_vars(socket),
    do: Variables.merge(socket.assigns.globals, collection_vars(socket))

  defp collection_vars(socket) do
    cid = socket.assigns.request.collection_id

    case Enum.find(socket.assigns.collections, &(&1.id == cid)) do
      %Collection{variables: vars} -> vars
      _ -> []
    end
  end

  defp load_globals do
    Globals.list()
  catch
    :exit, _ -> []
  end

  defp parse_globals_params(params), do: parse_vars_params(params)

  defp parse_vars_params(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {idx_str, _} -> String.to_integer(idx_str) end)
    |> Enum.map(fn {_idx, row} ->
      %{
        name: Map.get(row, "name", ""),
        value: Map.get(row, "value", ""),
        enabled: Map.get(row, "enabled", "false") in ["true", true, "on"]
      }
    end)
  end

  defp parse_vars_params(_), do: []

  # Persiste las vars de una colección y refresca el modal (si sigue abierto sobre
  # esa colección) + el listado de colecciones.
  defp persist_collection_vars(socket, coll_id, vars) do
    try_call(fn -> GrpcCollections.set_variables(coll_id, vars) end)

    modal_state =
      case socket.assigns.collection_vars_modal do
        %{collection_id: ^coll_id} = state -> %{state | vars: vars}
        other -> other
      end

    socket =
      socket
      |> assign(:collection_vars_modal, modal_state)
      |> refresh_collections()

    {:noreply, socket}
  end

  # ---------- Helpers de colecciones ----------

  defp load_collections do
    GrpcCollections.list()
  catch
    :exit, _ -> []
  end

  defp refresh_collections(socket),
    do: assign(socket, :collections, load_collections())

  # Dispara la descarga del JSON en el navegador vía el hook FileDownload
  # (`download:file`), igual que el export REST.
  defp download_json(socket, name, json) do
    push_event(socket, "download:file", %{
      filename: GrpcCollectionExport.suggested_filename(name),
      content: json,
      mime: "application/json"
    })
  end

  defp imported_flash(locale, 1), do: Translations.t(locale, "grpc.flashes.imported_one")

  defp imported_flash(locale, count),
    do: Translations.t(locale, "grpc.flashes.imported_many", count: count)

  # Ejecuta una mutación del repo tragando `:exit` (repo ausente en test env
  # sin storage). Devuelve el valor de la función, o nil si el repo no está.
  defp try_call(fun) when is_function(fun, 0) do
    fun.()
  catch
    :exit, _ -> nil
  end

  defp toggle(set, id) do
    if MapSet.member?(set, id), do: MapSet.delete(set, id), else: MapSet.put(set, id)
  end

  defp request_name(form_name, fallback) do
    case String.trim(to_string(form_name)) do
      "" -> if(fallback in [nil, ""], do: "Untitled", else: fallback)
      name -> name
    end
  end

  defp find_request(collections, cid, rid) do
    with %Collection{requests: reqs} <- Enum.find(collections, &(&1.id == cid)),
         %Request{} = req <- Enum.find(reqs, &(&1.id == rid)) do
      req
    else
      _ -> nil
    end
  end

  # ---------- Helpers de tabs ----------

  # Mata el Task en vuelo de `tab_id` si lo hay (al cerrar la tab).
  defp kill_task(socket, tab_id) do
    case Map.get(socket.assigns.send_tasks, tab_id) do
      %Task{pid: pid} -> Task.Supervisor.terminate_child(TestFlowPhx.TaskSupervisor, pid)
      _ -> :ok
    end
  end

  defp list_proto_sets do
    GrpcProtoSets.list()
  catch
    :exit, _ -> []
  end

  defp create_set_from_upload(tmp, client_name) do
    content = File.read!(tmp)

    if String.ends_with?(String.downcase(client_name), ".zip") do
      GrpcProtoSets.create_from_zip(content, name: Path.rootname(Path.basename(client_name)))
    else
      GrpcProtoSets.create_from_file(content, client_name)
    end
  end

  # Activa un proto-set en la tab: fija proto_set_id + entry_file (primer entry),
  # limpia rutas legacy, recarga el descriptor y preselecciona service/method.
  defp activate_set(socket, %ProtoSet{} = set) do
    entry = List.first(set.entry_files) || List.first(set.files)

    socket
    |> TabState.update_active(fn req ->
      %{req | proto_set_id: set.id, entry_file: entry, proto_paths: [], import_paths: []}
    end)
    |> TabState.put_active_view()
    |> assign(:proto_sets, list_proto_sets())
    |> reload_proto_assigns()
    |> preselect_active()
    |> TabState.save()
  end

  # Preselecciona el primer service/method del descriptor cargado (solo en
  # selección/upload fresco; el cambio de tab/abrir NO preselect).
  defp preselect_active(socket) do
    case socket.assigns.proto do
      nil ->
        socket

      desc ->
        socket
        |> TabState.update_active(fn req -> Proto.preselect(req, desc) end)
        |> TabState.put_active_view()
    end
  end

  # Recarga el descriptor para la tab activa, sin preselect (preserva
  # service/method guardado). En cambio de tab no gritamos si el proto falta.
  defp load_active_proto(socket) do
    socket = reload_proto_assigns(socket)
    if is_nil(socket.assigns.proto), do: assign(socket, :proto_error, nil), else: socket
  end

  # Resuelve las rutas del request (proto-set o legacy) y carga el descriptor en
  # los assigns. Surfacea el error de protoc si lo hay.
  defp reload_proto_assigns(socket) do
    req = socket.assigns.request

    case resolve_for_load(req) do
      {:ok, paths, import_paths} ->
        case ProtoLoader.load(paths, import_paths: import_paths) do
          {:ok, desc} ->
            socket
            |> assign(:proto, desc)
            |> assign(:proto_error, nil)
            |> assign(:proto_names, Enum.map(paths, &Path.basename/1))

          {:error, msg} ->
            socket |> assign(:proto, nil) |> assign(:proto_error, msg) |> assign(:proto_names, [])
        end

      :none ->
        socket |> assign(:proto, nil) |> assign(:proto_error, nil) |> assign(:proto_names, [])
    end
  end

  # Preferencia: proto-set (portable) → rutas resueltas; si no, rutas legacy.
  defp resolve_for_load(%Request{proto_set_id: id, entry_file: entry})
       when is_binary(id) and is_binary(entry) and entry != "" do
    {proto_paths, import_paths} = GrpcProtoSets.resolve_paths(id, entry)
    {:ok, proto_paths, import_paths}
  end

  defp resolve_for_load(%Request{proto_paths: [_ | _] = paths, import_paths: import_paths}),
    do: {:ok, paths, import_paths}

  defp resolve_for_load(_), do: :none

  @doc "Nombres de las variables globales habilitadas (para el hint del template)."
  def enabled_var_names(globals) do
    for %{name: name, enabled: true} <- globals, name != "", do: name
  end

  # ---------- Componentes ----------

  @doc "Lista numerada de mensajes (stream), cada uno como JSON pretty."
  attr :messages, :list, required: true

  def stream_list(assigns) do
    ~H"""
    <div class="space-y-2">
      <pre
        :for={{msg, i} <- Enum.with_index(@messages)}
        class="text-xs font-mono whitespace-pre-wrap rounded bg-zinc-50 dark:bg-zinc-800 p-2"
      ><span class="text-zinc-400">{i + 1}</span>
    {Format.pretty(msg)}</pre>
    </div>
    """
  end

  @doc """
  Barra de tabs gRPC. Componente propio (no reusa el `tab_bar` REST, que muestra
  método HTTP): acá la etiqueta es el nombre del request y, si hay, el método RPC.
  """
  attr :tabs, :list, required: true
  attr :active_id, :string, default: nil
  attr :in_flight_tabs, :any, default: nil
  attr :locale, :string, required: true

  def grpc_tab_bar(assigns) do
    assigns = assign_new(assigns, :in_flight_tabs, fn -> MapSet.new() end)

    ~H"""
    <div class="flex items-end gap-0.5 border-b border-zinc-200 dark:border-zinc-800 overflow-x-auto">
      <div
        :for={tab <- @tabs}
        class={[
          "flex items-center rounded-t-md border-x border-t shrink-0",
          if(tab.id == @active_id,
            do: "bg-white dark:bg-zinc-900 border-zinc-300 dark:border-zinc-700 -mb-px",
            else:
              "bg-zinc-50 dark:bg-zinc-800 border-transparent hover:bg-zinc-100 dark:hover:bg-zinc-700"
          )
        ]}
      >
        <button
          type="button"
          phx-click="select_tab"
          phx-value-id={tab.id}
          class="flex items-center gap-2 px-3 py-1.5 text-sm"
          title={tab.target}
        >
          <span class="truncate max-w-[12rem]">{grpc_tab_label(tab, @locale)}</span>
          <span :if={tab.method != ""} class="text-zinc-400 font-mono text-xs shrink-0">
            {tab.method}
          </span>
          <span :if={MapSet.member?(@in_flight_tabs, tab.id)} class="text-zinc-400 animate-pulse">
            ●
          </span>
        </button>
        <button
          type="button"
          phx-click="close_tab"
          phx-value-id={tab.id}
          aria-label={Translations.t(@locale, "grpc.aria.close_tab")}
          class="px-2 py-1.5 text-zinc-400 hover:text-red-600 text-sm"
        >
          ×
        </button>
      </div>
      <button
        type="button"
        phx-click="new_tab"
        aria-label={Translations.t(@locale, "grpc.aria.new_tab")}
        class="px-3 py-1.5 text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 text-sm shrink-0"
      >
        +
      </button>
    </div>
    """
  end

  defp grpc_tab_label(%{name: name}, _locale) when is_binary(name) and name != "", do: name
  defp grpc_tab_label(_, locale), do: Translations.t(locale, "grpc.untitled")

  @doc """
  Sidebar de colecciones gRPC: crear, listar (expandible), guardar el request
  actual y abrir/eliminar requests guardados. Espejo simplificado del sidebar
  REST (sin método HTTP, sin export/import — aún no aplican a gRPC).
  """
  attr :collections, :list, required: true
  attr :expanded, :any, required: true
  attr :request, Request, required: true
  attr :locale, :string, required: true

  def grpc_collections_sidebar(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex items-center justify-between">
        <h2 class="text-sm font-semibold">{Translations.t(@locale, "grpc.collections")}</h2>
        <div class="flex items-center gap-1">
          <button
            :if={@collections != []}
            type="button"
            phx-click="export_all_grpc_collections"
            class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100 px-1"
          >
            {Translations.t(@locale, "grpc.export_all")}
          </button>
          <label
            for="grpc-import-file-input"
            title={Translations.t(@locale, "grpc.import_title")}
            class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100 px-1 cursor-pointer"
          >
            {Translations.t(@locale, "grpc.import")}
          </label>
          <input
            id="grpc-import-file-input"
            type="file"
            accept="application/json,.json"
            phx-hook="FileImport"
            class="hidden"
          />
        </div>
      </div>

      <form phx-submit="save_to_collection" class="space-y-1">
        <input
          type="text"
          name="name"
          value={@request.name}
          placeholder={Translations.t(@locale, "grpc.request_name_placeholder")}
          autocomplete="off"
          class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 text-xs dark:bg-zinc-800"
        />
        <div class="flex gap-1">
          <select
            name="collection_id"
            disabled={@collections == []}
            class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 text-xs dark:bg-zinc-800 disabled:opacity-50"
          >
            <option value="">{Translations.t(@locale, "grpc.collection_select")}</option>
            <option :for={c <- @collections} value={c.id} selected={c.id == @request.collection_id}>
              {c.name}
            </option>
          </select>
          <button
            type="submit"
            disabled={@collections == []}
            class="px-2 py-1 rounded-md bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900 text-xs font-medium hover:opacity-90 disabled:opacity-40"
          >
            {Translations.t(@locale, "grpc.save")}
          </button>
        </div>
      </form>

      <form phx-submit="new_collection" class="flex gap-1">
        <input
          type="text"
          name="name"
          placeholder={Translations.t(@locale, "grpc.new_collection_placeholder")}
          autocomplete="off"
          class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 text-xs dark:bg-zinc-800"
        />
      </form>

      <p :if={@collections == []} class="text-xs text-zinc-400 dark:text-zinc-500 italic px-1">
        {Translations.t(@locale, "grpc.no_collections")}
      </p>

      <ul class="space-y-1">
        <li :for={c <- @collections} class="text-sm">
          <div class="flex items-center gap-1 rounded px-1 py-0.5 group hover:bg-zinc-100 dark:hover:bg-zinc-800">
            <button
              type="button"
              phx-click="toggle_collection"
              phx-value-id={c.id}
              class="text-zinc-400 w-4 text-xs"
              aria-label={Translations.t(@locale, "grpc.aria.toggle_collection")}
            >
              {if MapSet.member?(@expanded, c.id), do: "▼", else: "▶"}
            </button>
            <span class="flex-1 truncate" title={c.name}>{c.name}</span>
            <span class="text-xs text-zinc-400">{length(c.requests)}</span>
            <button
              type="button"
              phx-click="export_grpc_collection"
              phx-value-id={c.id}
              aria-label={Translations.t(@locale, "grpc.aria.export_collection")}
              title={Translations.t(@locale, "grpc.aria.export_collection")}
              class="text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 px-1 invisible group-hover:visible text-xs"
            >
              ↓
            </button>
            <button
              type="button"
              phx-click="open_collection_vars_modal"
              phx-value-id={c.id}
              aria-label="Variables de colección"
              title={"Variables (#{length(c.variables)})"}
              class={[
                "px-1 invisible group-hover:visible text-xs",
                if(c.variables != [],
                  do: "text-emerald-600 dark:text-emerald-400 hover:text-emerald-800",
                  else: "text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100"
                )
              ]}
            >
              {"{x}"}
            </button>
            <button
              type="button"
              phx-click="delete_collection"
              phx-value-id={c.id}
              aria-label={Translations.t(@locale, "grpc.aria.delete_collection")}
              data-confirm={Translations.t(@locale, "grpc.delete_collection_confirm", name: c.name)}
              class="text-zinc-300 hover:text-red-600 px-1 invisible group-hover:visible"
            >
              ×
            </button>
          </div>

          <ul :if={MapSet.member?(@expanded, c.id)} class="pl-6 space-y-0.5 mt-1">
            <li :if={c.requests == []} class="text-xs text-zinc-400 italic py-1">
              {Translations.t(@locale, "grpc.empty_collection")}
            </li>
            <li :for={r <- c.requests} class="flex items-center gap-1 group">
              <button
                type="button"
                phx-click="open_grpc_request"
                phx-value-collection-id={c.id}
                phx-value-request-id={r.id}
                class="flex-1 flex items-center gap-2 text-left text-xs rounded px-1 py-0.5 hover:bg-zinc-100 dark:hover:bg-zinc-800"
              >
                <span class="truncate">{r.name}</span>
                <span :if={r.method != ""} class="text-zinc-400 font-mono shrink-0">{r.method}</span>
              </button>
              <button
                type="button"
                phx-click="delete_request_from_collection"
                phx-value-collection-id={c.id}
                phx-value-request-id={r.id}
                aria-label={Translations.t(@locale, "grpc.aria.delete_request")}
                class="text-zinc-300 hover:text-red-600 px-1 invisible group-hover:visible text-xs"
              >
                ×
              </button>
            </li>
          </ul>
        </li>
      </ul>
    </div>
    """
  end
end
