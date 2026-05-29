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

  alias TestFlowPhx.Domain.Grpc.{Request, Response}
  alias TestFlowPhx.Infrastructure.Storage.Paths
  alias TestFlowPhx.UseCases.{Globals, Variables}
  alias TestFlowPhx.UseCases.Grpc.{ProtoLoader, SendGrpcRequest}
  alias TestFlowPhxWeb.GrpcLive.{Format, Params, Proto}
  alias TestFlowPhxWeb.TesterComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "TestFlow gRPC")
      |> assign(:request, Request.new(%{target: "localhost:50051"}))
      |> assign(:globals, load_globals())
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

  # Variables aplicables a este request. Por ahora solo globals; las variables
  # por colección llegan con N.11 (colecciones mixtas REST+gRPC).
  defp active_vars(socket), do: Variables.merge(socket.assigns.globals, [])

  defp load_globals do
    Globals.list()
  catch
    :exit, _ -> []
  end

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
end
