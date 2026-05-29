defmodule TestFlowPhxWeb.GrpcLive.TabState do
  @moduledoc """
  Helpers (casi puros) para el estado de tabs en la LiveView gRPC.

  Espejo de `TestFlowPhxWeb.RestLive.TabState`, pero con las preocupaciones
  extra del tester gRPC: además del request/response por tab, cada tab tiene
  su propio estado de streaming en vivo (`streaming_tabs`, `stream_messages_by_tab`,
  `cancelled_tabs`) y su task en vuelo (`send_tasks`). La vista derivada
  (`request`, `response`, `in_flight?`, `streaming?`, `stream_messages`,
  `cancelled?`) se recalcula desde esos mapas base y el `active_tab_id`.

  Cada función toma el socket y devuelve un socket nuevo, para que `index` se
  mantenga enfocado en rutear eventos.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TestFlowPhx.Domain.Grpc.Request
  alias TestFlowPhx.UseCases.Grpc.GrpcTabs

  @doc """
  Devuelve `{tabs, active_id}` para sembrar `mount`. Hace fallback a una tab
  fresca cuando no hay tabs persistidas O cuando el repo no está corriendo
  (test env sin storage).
  """
  @spec load_or_seed() :: {[Request.t()], String.t()}
  def load_or_seed do
    case load_persisted() do
      {[], _} ->
        seed = new_request()
        {[seed], seed.id}

      {tabs, active_id} ->
        active =
          if active_id && Enum.any?(tabs, &(&1.id == active_id)),
            do: active_id,
            else: hd(tabs).id

        {tabs, active}
    end
  end

  @doc "Construye el request default usado para sembrar una tab nueva."
  @spec new_request() :: Request.t()
  def new_request do
    Request.new(
      id: Request.new_id(),
      name: "Untitled",
      target: "localhost:50051",
      metadata: [Request.empty_kv()],
      body_text: ""
    )
  end

  @doc """
  Aplica `fun` al request de la tab activa y refresca la vista derivada.
  """
  @spec update_active(Phoenix.LiveView.Socket.t(), (Request.t() -> Request.t())) ::
          Phoenix.LiveView.Socket.t()
  def update_active(socket, fun) when is_function(fun, 1) do
    active_id = socket.assigns.active_tab_id

    tabs =
      Enum.map(socket.assigns.tabs, fn t ->
        if t.id == active_id, do: fun.(t), else: t
      end)

    socket
    |> assign(:tabs, tabs)
    |> put_active_view()
  end

  @doc """
  Recalcula los assigns derivados a partir de los mapas base y el
  `active_tab_id`. Llamar tras cada mutación que toque `tabs`, `responses`,
  `in_flight_tabs`, `streaming_tabs`, `cancelled_tabs`, `stream_messages_by_tab`
  o `active_tab_id`.
  """
  @spec put_active_view(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def put_active_view(socket) do
    active_id = socket.assigns.active_tab_id
    active = Enum.find(socket.assigns.tabs, &(&1.id == active_id)) || new_request()

    socket
    |> assign(:request, active)
    |> assign(:response, Map.get(socket.assigns.responses, active_id))
    |> assign(:in_flight?, MapSet.member?(socket.assigns.in_flight_tabs, active_id))
    |> assign(:streaming?, MapSet.member?(socket.assigns.streaming_tabs, active_id))
    |> assign(:cancelled?, MapSet.member?(socket.assigns.cancelled_tabs, active_id))
    |> assign(:stream_messages, Map.get(socket.assigns.stream_messages_by_tab, active_id, []))
  end

  @doc """
  Limpia todo el estado runtime (no persistido) asociado a `tab_id`: response,
  banderas de in-flight/streaming/cancelado y el buffer de mensajes. Usar al
  cerrar/reemplazar una tab.
  """
  @spec clear_runtime(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def clear_runtime(socket, tab_id) do
    socket
    |> Phoenix.Component.update(:responses, &Map.delete(&1, tab_id))
    |> Phoenix.Component.update(:in_flight_tabs, &MapSet.delete(&1, tab_id))
    |> Phoenix.Component.update(:streaming_tabs, &MapSet.delete(&1, tab_id))
    |> Phoenix.Component.update(:cancelled_tabs, &MapSet.delete(&1, tab_id))
    |> Phoenix.Component.update(:stream_messages_by_tab, &Map.delete(&1, tab_id))
  end

  @doc """
  Hace demonitor de cualquier task ref que perteneciera a `tab_id` y los
  remueve de `:send_refs`. Usar al cerrar una tab para que trabajo en vuelo de
  esa tab no pueda crashear la LiveView después.
  """
  @spec drop_send_refs_for(Phoenix.LiveView.Socket.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def drop_send_refs_for(socket, tab_id) do
    kept =
      Enum.reduce(socket.assigns.send_refs, %{}, fn {ref, tid}, acc ->
        if tid == tab_id do
          Process.demonitor(ref, [:flush])
          acc
        else
          Map.put(acc, ref, tid)
        end
      end)

    assign(socket, :send_refs, kept)
  end

  @doc """
  Persiste `:tabs` / `:active_tab_id` vía el use case GrpcTabs. Traga `:exit`
  para que un repo ausente (test env) no crashee la LiveView.
  """
  @spec save(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def save(socket) do
    GrpcTabs.save(socket.assigns.tabs, socket.assigns.active_tab_id)
    socket
  catch
    :exit, _ -> socket
  end

  # ----- Private -----

  defp load_persisted do
    {GrpcTabs.list(), GrpcTabs.active_id()}
  catch
    :exit, _ -> {[], nil}
  end
end
