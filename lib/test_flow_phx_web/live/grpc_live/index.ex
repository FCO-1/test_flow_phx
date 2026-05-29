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

  Mantiene un solo request en vuelo (sin tabs aún — eso viene en una sub-fase).
  La presentación nunca llama infraestructura directo: todo vía use cases.
  """

  use TestFlowPhxWeb, :live_view

  alias TestFlowPhx.Domain.Grpc.{Collection, Request, Response}
  alias TestFlowPhx.Infrastructure.Storage.Paths
  alias TestFlowPhx.UseCases.{Globals, Variables}
  alias TestFlowPhx.UseCases.Grpc.{GrpcCollections, ProtoLoader, SendGrpcRequest}
  alias TestFlowPhxWeb.GrpcLive.{Format, Params, Proto}
  alias TestFlowPhxWeb.TesterComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "TestFlow gRPC")
      |> assign(:request, Request.new(%{target: "localhost:50051"}))
      |> assign(:globals, load_globals())
      |> assign(:collections, load_collections())
      |> assign(:expanded_collections, MapSet.new())
      |> assign(:proto, nil)
      |> assign(:proto_error, nil)
      |> assign(:proto_names, [])
      |> assign(:response, nil)
      |> assign(:in_flight?, false)
      |> assign(:send_ref, nil)
      |> assign(:send_task, nil)
      |> assign(:streaming?, false)
      |> assign(:stream_messages, [])
      |> assign(:cancelled?, false)
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

  # ---------- Edición del request ----------

  def handle_event("validate", %{"request" => params}, socket) do
    request = Params.apply(socket.assigns.request, socket.assigns.proto, params)
    {:noreply, assign(socket, :request, request)}
  end

  def handle_event("add_kv_row", %{"field" => "metadata"}, socket) do
    rows = socket.assigns.request.metadata ++ [Request.empty_kv()]
    {:noreply, assign(socket, :request, %{socket.assigns.request | metadata: rows})}
  end

  def handle_event("remove_kv_row", %{"field" => "metadata", "index" => idx}, socket) do
    rows = List.delete_at(socket.assigns.request.metadata, String.to_integer(idx))
    {:noreply, assign(socket, :request, %{socket.assigns.request | metadata: rows})}
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

        socket =
          case try_call(fn -> GrpcCollections.add_request(cid, req) end) do
            %Request{} = saved -> assign(socket, :request, saved)
            _ -> socket
          end

        {:noreply, refresh_collections(socket)}
    end
  end

  # Abre un request guardado en el form. Preserva su service/method; recarga
  # el descriptor desde proto_paths para repoblar los dropdowns (sin preselect,
  # que pisaría la selección guardada).
  def handle_event(
        "open_grpc_request",
        %{"collection-id" => cid, "request-id" => rid},
        socket
      ) do
    case find_request(socket.assigns.collections, cid, rid) do
      %Request{} = req ->
        socket =
          socket
          |> assign(:request, req)
          |> assign(:response, nil)
          |> reload_proto(req.proto_paths)

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
    if socket.assigns.in_flight? do
      {:noreply, socket}
    else
      request =
        case params do
          %{"request" => form} -> Params.apply(socket.assigns.request, socket.assigns.proto, form)
          _ -> socket.assigns.request
        end

      streaming? = Proto.streaming_method?(socket.assigns.proto, request.service, request.method)
      lv = self()

      # on_message empuja cada mensaje al LV en vivo; el executor igual acumula
      # todo en Response.messages para el resultado final.
      vars = active_vars(socket)

      task =
        Task.Supervisor.async_nolink(TestFlowPhx.TaskSupervisor, fn ->
          SendGrpcRequest.execute(request,
            vars: vars,
            on_message: fn msg -> Kernel.send(lv, {:grpc_msg, msg}) end
          )
        end)

      socket =
        socket
        |> assign(:request, request)
        |> assign(:in_flight?, true)
        |> assign(:streaming?, streaming?)
        |> assign(:stream_messages, [])
        |> assign(:cancelled?, false)
        |> assign(:send_ref, task.ref)
        |> assign(:send_task, task)
        |> assign(:response, nil)

      {:noreply, socket}
    end
  end

  # Cancela un stream en curso matando el Task: la conexión HTTP/2 está linkeada
  # al proceso del Task (Http2Client.connect/start_link), así que muere con él
  # (RST_STREAM). El {:DOWN} resultante se ignora vía la bandera cancelled?.
  def handle_event("cancel", _params, socket) do
    case socket.assigns.send_task do
      %Task{pid: pid} ->
        Task.Supervisor.terminate_child(TestFlowPhx.TaskSupervisor, pid)

        {:noreply,
         socket
         |> assign(:cancelled?, true)
         |> assign(:in_flight?, false)
         |> assign(:streaming?, false)
         |> assign(:send_task, nil)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:grpc_msg, msg}, socket) do
    {:noreply, update(socket, :stream_messages, &(&1 ++ [msg]))}
  end

  def handle_info({ref, %Response{} = response}, %{assigns: %{send_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     socket
     |> assign(:response, response)
     |> assign(:in_flight?, false)
     |> assign(:streaming?, false)
     |> assign(:send_ref, nil)
     |> assign(:send_task, nil)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{send_ref: ref}} = socket) do
    socket =
      socket
      |> assign(:in_flight?, false)
      |> assign(:streaming?, false)
      |> assign(:send_ref, nil)
      |> assign(:send_task, nil)

    # Si fue cancelación del usuario, no es un error: la lista en vivo queda.
    socket =
      if socket.assigns.cancelled? do
        socket
      else
        assign(socket, :response, %Response{
          error: %{type: :unknown, message: "el envío falló: #{inspect(reason)}", code: nil}
        })
      end

    {:noreply, socket}
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

  # Recarga el descriptor desde los .proto guardados, sin preselect (preserva
  # el service/method del request). Si los archivos ya no están, deja el proto
  # actual intacto.
  defp reload_proto(socket, paths) when is_list(paths) and paths != [] do
    case ProtoLoader.load(paths) do
      {:ok, desc} ->
        socket
        |> assign(:proto, desc)
        |> assign(:proto_error, nil)
        |> assign(:proto_names, Enum.map(paths, &Path.basename/1))

      {:error, _} ->
        socket
    end
  end

  defp reload_proto(socket, _paths), do: socket

  @doc "Nombres de las variables globales habilitadas (para el hint del template)."
  def enabled_var_names(globals) do
    for %{name: name, enabled: true} <- globals, name != "", do: name
  end

  # ---------- Helpers de carga ----------

  defp load_into_socket(socket, paths) do
    case ProtoLoader.load(paths) do
      {:ok, desc} ->
        request = Proto.preselect(socket.assigns.request, desc)

        socket
        |> assign(:proto, desc)
        |> assign(:proto_error, nil)
        |> assign(:proto_names, Enum.map(paths, &Path.basename/1))
        |> assign(:request, %{request | proto_paths: paths})

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
