defmodule TestFlowPhxWeb.RestLive.TabState do
  @moduledoc """
  Pure(-ish) helpers that own the tab-state portion of the REST LiveView.

  Each function takes the socket and returns a new socket — keeps the
  index module focused on event routing, not on the bookkeeping of
  active_request/responses/in_flight_tabs.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TestFlowPhx.Domain.Request
  alias TestFlowPhx.UseCases.Tabs

  @doc """
  Returns `{tabs, active_id}` to seed mount. Falls back to a fresh
  Untitled when no tabs have been persisted yet OR when the repo is not
  running (test env without storage).
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

  @doc "Builds the default empty request used to seed a new tab."
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
  Applies `fun` to the request struct of the currently-active tab and
  refreshes the derived `:active_request` view.
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
  Recomputes the derived assigns (`active_request`, `response`,
  `in_flight?`) from the underlying maps and the current `active_tab_id`.
  Call after every mutation that touches `tabs`, `responses`,
  `in_flight_tabs` or `active_tab_id`.
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
  Demonitors any task refs that belonged to `tab_id` and removes them
  from the `:send_refs` map. Use when closing a tab so in-flight work
  for that tab cannot crash the LiveView later.
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
  Persists the current `:tabs` / `:active_tab_id` via the Tabs use case.
  Swallows `:exit` so a missing repo (test env) does not crash the
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
