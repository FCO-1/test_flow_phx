defmodule TestFlowPhxWeb.RestLive.TabState do
  @moduledoc """
  Helpers (casi puros) que se encargan del estado de tabs en la
  LiveView REST.

  Cada función toma el socket y devuelve un socket nuevo — así el
  módulo `index` se mantiene enfocado en rutear eventos, sin cargar con
  el bookkeeping de active_request / responses / in_flight_tabs.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TestFlowPhx.Domain.Rest.Request
  alias TestFlowPhx.UseCases.Tabs

  @doc """
  Devuelve `{tabs, active_id}` para sembrar `mount`. Hace fallback a
  una tab Untitled fresca cuando no hay tabs persistidas todavía O
  cuando el repo no está corriendo (test env sin storage).
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

  @doc "Construye el request vacío default usado para sembrar una tab nueva."
  @spec new_request() :: Request.t()
  def new_request do
    Request.new(
      id: Request.new_id(),
      name: "Untitled",
      method: "GET",
      url: "",
      query_params: [Request.empty_kv()],
      headers: [Request.empty_kv()],
      body_type: :none,
      body_text: "",
      auth: %{type: :none}
    )
  end

  @doc """
  Aplica `fun` al struct request de la tab activa actual y refresca la
  vista derivada `:active_request`.
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
  Recalcula los assigns derivados (`active_request`, `response`,
  `in_flight?`) a partir de los mapas base y el `active_tab_id` actual.
  Llamar después de cada mutación que toque `tabs`, `responses`,
  `in_flight_tabs` o `active_tab_id`.
  """
  @spec put_active_view(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def put_active_view(socket) do
    active_id = socket.assigns.active_tab_id
    active = Enum.find(socket.assigns.tabs, &(&1.id == active_id))

    socket
    |> assign(:active_request, active || new_request())
    |> assign(:response, Map.get(socket.assigns.responses, active_id))
    |> assign(:in_flight?, MapSet.member?(socket.assigns.in_flight_tabs, active_id))
  end

  @doc """
  Hace demonitor de cualquier task ref que perteneciera a `tab_id` y
  los remueve del map `:send_refs`. Usar al cerrar una tab para que
  trabajo en vuelo de esa tab no pueda crashear la LiveView después.
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
  Persiste `:tabs` / `:active_tab_id` actuales vía el use case Tabs.
  Traga `:exit` para que un repo ausente (test env) no crashee la
  LiveView.
  """
  @spec save(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def save(socket) do
    Tabs.save(socket.assigns.tabs, socket.assigns.active_tab_id)
    socket
  catch
    :exit, _ -> socket
  end

  # ----- Private -----

  defp load_persisted do
    {Tabs.list(), Tabs.active_id()}
  catch
    :exit, _ -> {[], nil}
  end
end
