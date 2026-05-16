defmodule TestFlowPhxWeb.TesterLive do
  @moduledoc """
  Top-level LiveView for the REST endpoint tester.

  Fase E — multi-tab workspace. Each tab is a `%Request{}` with its own
  response slot and in-flight state. Tabs are persisted via
  `UseCases.Tabs` so a reload restores the workspace.
  """

  use TestFlowPhxWeb, :live_view

  alias TestFlowPhx.Domain.{Request, Response}
  alias TestFlowPhx.UseCases.{SendRequest, Tabs}
  alias TestFlowPhxWeb.RequestParams
  alias TestFlowPhxWeb.TesterComponents

  @impl true
  def mount(_params, _session, socket) do
    {tabs, active_id} = load_or_seed_tabs()

    socket =
      socket
      |> assign(:page_title, "TestFlow")
      |> assign(:tabs, tabs)
      |> assign(:active_tab_id, active_id)
      |> assign(:responses, %{})
      |> assign(:in_flight_tabs, MapSet.new())
      |> assign(:send_refs, %{})
      |> assign(:request_subtab, :params)
      |> assign(:response_subtab, :body)
      |> assign(:sidebar_section, :collections)
      |> put_active_view()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-[calc(100vh-4rem)] gap-0 -mx-4">
      <aside class="w-64 shrink-0 border-r border-zinc-200 bg-zinc-50 p-3 overflow-y-auto">
        <div class="flex gap-1 mb-3">
          <button
            type="button"
            class={sidebar_tab_class(@sidebar_section == :collections)}
            phx-click="sidebar_section"
            phx-value-section="collections"
          >
            Collections
          </button>
          <button
            type="button"
            class={sidebar_tab_class(@sidebar_section == :history)}
            phx-click="sidebar_section"
            phx-value-section="history"
          >
            History
          </button>
        </div>
        <p class="text-xs text-zinc-500 px-2 py-4">
          <%= if @sidebar_section == :collections do %>
            (vacío — añade colecciones en la Fase F)
          <% else %>
            (vacío — el historial aparece en la Fase G)
          <% end %>
        </p>
      </aside>

      <main class="flex-1 flex flex-col min-w-0 p-4 gap-4 overflow-y-auto">
        <TesterComponents.tab_bar
          tabs={@tabs}
          active_id={@active_tab_id}
          in_flight_tabs={@in_flight_tabs}
        />

        <form id="request-form" phx-change="update_request" phx-submit="send" class="space-y-4">
          <input type="hidden" name="active_tab_id" value={@active_tab_id} />
          <TesterComponents.method_url_bar request={@active_request} in_flight?={@in_flight?} />
          <TesterComponents.request_subtabs active={@request_subtab} />
          <div class="rounded-lg border border-zinc-200 bg-white p-4 min-h-[12rem]">
            <%= case @request_subtab do %>
              <% :params -> %>
                <TesterComponents.kv_editor
                  rows={@active_request.query_params}
                  field="query_params"
                />
              <% :headers -> %>
                <TesterComponents.kv_editor
                  rows={@active_request.headers}
                  field="headers"
                  placeholder_key="Header-Name"
                />
              <% :body -> %>
                <TesterComponents.body_editor request={@active_request} />
              <% :auth -> %>
                <TesterComponents.auth_editor request={@active_request} />
            <% end %>
          </div>
        </form>

        <TesterComponents.response_panel
          response={@response}
          in_flight?={@in_flight?}
          active={@response_subtab}
        />
      </main>
    </div>
    """
  end

  # ---------- Sidebar / subtabs ----------

  @impl true
  def handle_event("sidebar_section", %{"section" => section}, socket)
      when section in ["collections", "history"] do
    {:noreply, assign(socket, :sidebar_section, String.to_existing_atom(section))}
  end

  def handle_event("set_request_subtab", %{"subtab" => st}, socket)
      when st in ["params", "headers", "body", "auth"] do
    {:noreply, assign(socket, :request_subtab, String.to_existing_atom(st))}
  end

  def handle_event("set_response_subtab", %{"subtab" => st}, socket)
      when st in ["body", "headers", "raw"] do
    {:noreply, assign(socket, :response_subtab, String.to_existing_atom(st))}
  end

  # ---------- Tab management ----------

  def handle_event("select_tab", %{"id" => id}, socket) do
    if Enum.any?(socket.assigns.tabs, &(&1.id == id)) do
      socket =
        socket
        |> assign(:active_tab_id, id)
        |> put_active_view()
        |> save_tabs()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("new_tab", _params, socket) do
    new_tab = new_tab_request()

    socket =
      socket
      |> update(:tabs, &(&1 ++ [new_tab]))
      |> assign(:active_tab_id, new_tab.id)
      |> put_active_view()
      |> save_tabs()

    {:noreply, socket}
  end

  def handle_event("close_tab", %{"id" => id}, socket) do
    tabs = socket.assigns.tabs

    case Enum.find_index(tabs, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      idx ->
        remaining = List.delete_at(tabs, idx)

        new_active_id =
          cond do
            socket.assigns.active_tab_id != id ->
              socket.assigns.active_tab_id

            remaining == [] ->
              nil

            true ->
              next_idx = min(idx, length(remaining) - 1)
              Enum.at(remaining, next_idx).id
          end

        {tabs, active_id} =
          if remaining == [] do
            fresh = new_tab_request()
            {[fresh], fresh.id}
          else
            {remaining, new_active_id}
          end

        socket =
          socket
          |> assign(:tabs, tabs)
          |> assign(:active_tab_id, active_id)
          |> update(:responses, &Map.delete(&1, id))
          |> update(:in_flight_tabs, &MapSet.delete(&1, id))
          |> drop_send_refs_for(id)
          |> put_active_view()
          |> save_tabs()

        {:noreply, socket}
    end
  end

  # ---------- Request editing ----------

  def handle_event("update_request", %{"request" => params}, socket) do
    socket =
      socket
      |> update_active_tab(fn req -> RequestParams.from_form(params, req) end)
      |> save_tabs()

    {:noreply, socket}
  end

  def handle_event("update_request", _params, socket), do: {:noreply, socket}

  def handle_event("add_kv_row", %{"field" => field}, socket)
      when field in ["query_params", "headers"] do
    key = String.to_existing_atom(field)

    socket =
      socket
      |> update_active_tab(fn req ->
        rows = Map.fetch!(req, key) ++ [Request.empty_kv()]
        Map.put(req, key, rows)
      end)
      |> save_tabs()

    {:noreply, socket}
  end

  def handle_event("remove_kv_row", %{"field" => field, "index" => idx_str}, socket)
      when field in ["query_params", "headers"] do
    key = String.to_existing_atom(field)
    idx = String.to_integer(idx_str)

    socket =
      socket
      |> update_active_tab(fn req ->
        rows =
          req
          |> Map.fetch!(key)
          |> List.delete_at(idx)
          |> case do
            [] -> [Request.empty_kv()]
            rs -> rs
          end

        Map.put(req, key, rows)
      end)
      |> save_tabs()

    {:noreply, socket}
  end

  def handle_event("format_json", _params, socket) do
    request = socket.assigns.active_request

    case Jason.decode(request.body_text) do
      {:ok, parsed} ->
        pretty = parsed |> Jason.encode_to_iodata!(pretty: true) |> IO.iodata_to_binary()

        socket =
          socket
          |> update_active_tab(fn req -> %{req | body_text: pretty} end)
          |> save_tabs()

        {:noreply, socket}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "JSON inválido — corrige antes de formatear.")}
    end
  end

  # ---------- Send ----------

  def handle_event("send", params, socket) do
    tab_id = socket.assigns.active_tab_id

    if MapSet.member?(socket.assigns.in_flight_tabs, tab_id) do
      {:noreply, socket}
    else
      # Use submit params if present (covers the race where the user types
      # and hits Send within the phx-debounce window — otherwise the active
      # tab may still hold the previous URL/method).
      socket =
        case params do
          %{"request" => form} ->
            update_active_tab(socket, fn req -> RequestParams.from_form(form, req) end)

          _ ->
            socket
        end

      request = socket.assigns.active_request

      task =
        Task.Supervisor.async_nolink(
          TestFlowPhx.TaskSupervisor,
          fn -> SendRequest.execute(request, record_history?: false) end
        )

      socket =
        socket
        |> update(:in_flight_tabs, &MapSet.put(&1, tab_id))
        |> update(:send_refs, &Map.put(&1, task.ref, tab_id))
        |> update(:responses, &Map.put(&1, tab_id, nil))
        |> assign(:response_subtab, :body)
        |> put_active_view()
        |> save_tabs()

      {:noreply, socket}
    end
  end

  # ---------- Task results ----------

  @impl true
  def handle_info({ref, {response, _history}}, socket) when is_reference(ref) do
    case Map.fetch(socket.assigns.send_refs, ref) do
      {:ok, tab_id} ->
        Process.demonitor(ref, [:flush])

        socket =
          socket
          |> update(:in_flight_tabs, &MapSet.delete(&1, tab_id))
          |> update(:send_refs, &Map.delete(&1, ref))
          |> update(:responses, &Map.put(&1, tab_id, response))
          |> put_active_view()

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) when is_reference(ref) do
    case Map.fetch(socket.assigns.send_refs, ref) do
      {:ok, tab_id} ->
        error_response = %Response{
          error: %{type: :unknown, message: "Task crashed: #{inspect(reason)}"}
        }

        socket =
          socket
          |> update(:in_flight_tabs, &MapSet.delete(&1, tab_id))
          |> update(:send_refs, &Map.delete(&1, ref))
          |> update(:responses, &Map.put(&1, tab_id, error_response))
          |> put_active_view()

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ---------- Tabs helpers ----------

  defp load_or_seed_tabs do
    case load_persisted_tabs() do
      {[], _} ->
        seed = new_tab_request()
        {[seed], seed.id}

      {tabs, active_id} ->
        active = if active_id && Enum.any?(tabs, &(&1.id == active_id)), do: active_id, else: hd(tabs).id
        {tabs, active}
    end
  end

  defp load_persisted_tabs do
    {Tabs.list(), Tabs.active_id()}
  catch
    :exit, _ -> {[], nil}
  end

  defp save_tabs(socket) do
    Tabs.save(socket.assigns.tabs, socket.assigns.active_tab_id)
    socket
  catch
    :exit, _ -> socket
  end

  defp new_tab_request do
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

  defp update_active_tab(socket, fun) do
    active_id = socket.assigns.active_tab_id

    tabs =
      Enum.map(socket.assigns.tabs, fn t ->
        if t.id == active_id, do: fun.(t), else: t
      end)

    socket
    |> assign(:tabs, tabs)
    |> put_active_view()
  end

  defp put_active_view(socket) do
    active_id = socket.assigns.active_tab_id
    active = Enum.find(socket.assigns.tabs, &(&1.id == active_id))

    socket
    |> assign(:active_request, active || new_tab_request())
    |> assign(:response, Map.get(socket.assigns.responses, active_id))
    |> assign(:in_flight?, MapSet.member?(socket.assigns.in_flight_tabs, active_id))
  end

  defp drop_send_refs_for(socket, tab_id) do
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

  defp sidebar_tab_class(active?) do
    base = "px-3 py-1.5 text-sm rounded-md transition-colors"

    if active? do
      base <> " bg-white border border-zinc-200 text-zinc-900 font-medium"
    else
      base <> " text-zinc-500 hover:text-zinc-800"
    end
  end
end
