defmodule TestFlowPhxWeb.GrpcLive.Index do
  @moduledoc """
  LiveView del tester gRPC. Vive en su propia carpeta (`live/grpc_live/`),
  separada de `rest_live/`: el switch entre protocolos es por **router**
  (`~p"/"` ↔ `~p"/grpc"`), no por estado compartido.

  Flujo (N.8, básico, unary + streaming-no-vivo):

    1. El usuario sube uno o más `.proto` → se guardan en `Paths.proto_dir/0`
       y se cargan con `ProtoLoader` (services/methods + registry).
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
  alias TestFlowPhx.Infrastructure.Storage.Paths
  alias TestFlowPhx.UseCases.{Globals, Variables}
  alias TestFlowPhx.UseCases.Grpc.{GrpcCollections, ProtoLoader, SendGrpcRequest}
  alias TestFlowPhxWeb.GrpcLive.{Format, Params, Proto, TabState}
  alias TestFlowPhxWeb.TesterComponents

  @impl true
  def mount(_params, _session, socket) do
    {tabs, active_id} = TabState.load_or_seed()

    socket =
      socket
      |> assign(:page_title, "TestFlow gRPC")
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
      |> assign(:proto, nil)
      |> assign(:proto_error, nil)
      |> assign(:proto_names, [])
      |> TabState.put_active_view()
      |> load_active_proto()
      |> allow_upload(:protos, accept: :any, max_entries: 10, auto_upload: false)

    {:ok, socket}
  end

  # ---------- Carga de .proto ----------

  @impl true
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("load_protos", _params, socket) do
    dir = Paths.proto_dir()
    File.mkdir_p!(dir)

    paths =
      consume_uploaded_entries(socket, :protos, fn %{path: tmp}, entry ->
        dest = Path.join(dir, entry.client_name)
        File.cp!(tmp, dest)
        {:ok, dest}
      end)

    socket =
      case paths do
        [] ->
          assign(socket, :proto_error, "no subiste ningún .proto")

        paths ->
          load_into_socket(socket, paths)
      end

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
      |> TabState.update_active(fn req -> %{req | metadata: req.metadata ++ [Request.empty_kv()]} end)
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

  # Abre un request guardado. Si ya hay una tab para ese request (mismo id),
  # restaura el contenido guardado en ella; si no, reemplaza la tab activa.
  # Recarga el descriptor desde proto_paths para repoblar los dropdowns; el
  # contenido guardado (service/method) se preserva (load_active_proto no hace
  # preselect).
  def handle_event(
        "open_grpc_request",
        %{"collection-id" => cid, "request-id" => rid},
        socket
      ) do
    case find_request(socket.assigns.collections, cid, rid) do
      %Request{} = req ->
        socket =
          socket
          |> open_into_tab(req)
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
            TabState.update_active(socket, fn req -> Params.apply(req, socket.assigns.proto, form) end)

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
                error: %{type: :unknown, message: "el envío falló: #{inspect(reason)}", code: nil}
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

  # ---------- Helpers de colecciones ----------

  defp load_collections do
    GrpcCollections.list()
  catch
    :exit, _ -> []
  end

  defp refresh_collections(socket),
    do: assign(socket, :collections, load_collections())

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

  # Carga `req` en una tab: si ya existe una tab con su id, restaura su
  # contenido (limpiando runtime); si no, reemplaza la tab activa en sitio
  # (la tab toma el id del request). Activa la tab resultante.
  defp open_into_tab(socket, %Request{} = req) do
    if Enum.any?(socket.assigns.tabs, &(&1.id == req.id)) do
      tabs = Enum.map(socket.assigns.tabs, fn t -> if t.id == req.id, do: req, else: t end)

      socket
      |> assign(:tabs, tabs)
      |> assign(:active_tab_id, req.id)
      |> TabState.clear_runtime(req.id)
    else
      old_id = socket.assigns.active_tab_id
      tabs = Enum.map(socket.assigns.tabs, fn t -> if t.id == old_id, do: req, else: t end)

      socket
      |> assign(:tabs, tabs)
      |> assign(:active_tab_id, req.id)
      |> TabState.clear_runtime(old_id)
    end
  end

  # Mata el Task en vuelo de `tab_id` si lo hay (al cerrar la tab).
  defp kill_task(socket, tab_id) do
    case Map.get(socket.assigns.send_tasks, tab_id) do
      %Task{pid: pid} -> Task.Supervisor.terminate_child(TestFlowPhx.TaskSupervisor, pid)
      _ -> :ok
    end
  end

  # Recarga el descriptor para la tab activa desde sus `proto_paths`, sin
  # preselect (preserva el service/method guardado). Si no hay paths o ya no
  # están en disco, limpia el proto (cada tab muestra solo lo suyo).
  defp load_active_proto(socket) do
    paths = socket.assigns.request.proto_paths

    with [_ | _] <- paths,
         {:ok, desc} <- ProtoLoader.load(paths) do
      socket
      |> assign(:proto, desc)
      |> assign(:proto_error, nil)
      |> assign(:proto_names, Enum.map(paths, &Path.basename/1))
    else
      _ ->
        socket
        |> assign(:proto, nil)
        |> assign(:proto_error, nil)
        |> assign(:proto_names, [])
    end
  end

  @doc "Nombres de las variables globales habilitadas (para el hint del template)."
  def enabled_var_names(globals) do
    for %{name: name, enabled: true} <- globals, name != "", do: name
  end

  # ---------- Helpers de carga ----------

  defp load_into_socket(socket, paths) do
    case ProtoLoader.load(paths) do
      {:ok, desc} ->
        socket
        |> assign(:proto, desc)
        |> assign(:proto_error, nil)
        |> assign(:proto_names, Enum.map(paths, &Path.basename/1))
        |> TabState.update_active(fn req -> %{Proto.preselect(req, desc) | proto_paths: paths} end)
        |> TabState.save()

      {:error, msg} ->
        socket
        |> assign(:proto, nil)
        |> assign(:proto_error, msg)
    end
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
            else: "bg-zinc-50 dark:bg-zinc-800 border-transparent hover:bg-zinc-100 dark:hover:bg-zinc-700"
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
          <span class="truncate max-w-[12rem]">{grpc_tab_label(tab)}</span>
          <span :if={tab.method != ""} class="text-zinc-400 font-mono text-xs shrink-0">{tab.method}</span>
          <span :if={MapSet.member?(@in_flight_tabs, tab.id)} class="text-zinc-400 animate-pulse">●</span>
        </button>
        <button
          type="button"
          phx-click="close_tab"
          phx-value-id={tab.id}
          aria-label="Close tab"
          class="px-2 py-1.5 text-zinc-400 hover:text-red-600 text-sm"
        >×</button>
      </div>
      <button
        type="button"
        phx-click="new_tab"
        aria-label="New tab"
        class="px-3 py-1.5 text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 text-sm shrink-0"
      >+</button>
    </div>
    """
  end

  defp grpc_tab_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp grpc_tab_label(_), do: "Untitled"

  @doc """
  Sidebar de colecciones gRPC: crear, listar (expandible), guardar el request
  actual y abrir/eliminar requests guardados. Espejo simplificado del sidebar
  REST (sin método HTTP, sin export/import — aún no aplican a gRPC).
  """
  attr :collections, :list, required: true
  attr :expanded, :any, required: true
  attr :request, Request, required: true

  def grpc_collections_sidebar(assigns) do
    ~H"""
    <div class="space-y-3">
      <h2 class="text-sm font-semibold">Colecciones</h2>

      <form phx-submit="save_to_collection" class="space-y-1">
        <input
          type="text"
          name="name"
          value={@request.name}
          placeholder="nombre del request"
          autocomplete="off"
          class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 text-xs dark:bg-zinc-800"
        />
        <div class="flex gap-1">
          <select
            name="collection_id"
            disabled={@collections == []}
            class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 text-xs dark:bg-zinc-800 disabled:opacity-50"
          >
            <option value="">colección…</option>
            <option :for={c <- @collections} value={c.id} selected={c.id == @request.collection_id}>
              {c.name}
            </option>
          </select>
          <button
            type="submit"
            disabled={@collections == []}
            class="px-2 py-1 rounded-md bg-zinc-900 text-white dark:bg-zinc-100 dark:text-zinc-900 text-xs font-medium hover:opacity-90 disabled:opacity-40"
          >
            Guardar
          </button>
        </div>
      </form>

      <form phx-submit="new_collection" class="flex gap-1">
        <input
          type="text"
          name="name"
          placeholder="+ Nueva colección"
          autocomplete="off"
          class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 text-xs dark:bg-zinc-800"
        />
      </form>

      <p :if={@collections == []} class="text-xs text-zinc-400 dark:text-zinc-500 italic px-1">
        Sin colecciones todavía.
      </p>

      <ul class="space-y-1">
        <li :for={c <- @collections} class="text-sm">
          <div class="flex items-center gap-1 rounded px-1 py-0.5 group hover:bg-zinc-100 dark:hover:bg-zinc-800">
            <button
              type="button"
              phx-click="toggle_collection"
              phx-value-id={c.id}
              class="text-zinc-400 w-4 text-xs"
              aria-label="Toggle collection"
            >{if MapSet.member?(@expanded, c.id), do: "▼", else: "▶"}</button>
            <span class="flex-1 truncate" title={c.name}>{c.name}</span>
            <span class="text-xs text-zinc-400">{length(c.requests)}</span>
            <button
              type="button"
              phx-click="delete_collection"
              phx-value-id={c.id}
              aria-label="Delete collection"
              data-confirm={"¿Borrar la colección \"" <> c.name <> "\"?"}
              class="text-zinc-300 hover:text-red-600 px-1 invisible group-hover:visible"
            >×</button>
          </div>

          <ul :if={MapSet.member?(@expanded, c.id)} class="pl-6 space-y-0.5 mt-1">
            <li :if={c.requests == []} class="text-xs text-zinc-400 italic py-1">(vacía)</li>
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
                aria-label="Delete request"
                class="text-zinc-300 hover:text-red-600 px-1 invisible group-hover:visible text-xs"
              >×</button>
            </li>
          </ul>
        </li>
      </ul>
    </div>
    """
  end
end
