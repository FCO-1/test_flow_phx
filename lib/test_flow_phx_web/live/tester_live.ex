defmodule TestFlowPhxWeb.TesterLive do
  @moduledoc """
  Top-level LiveView for the REST endpoint tester.

  Fase D — full request editor (method/url/params/headers/body/auth) +
  async Send via `UseCases.SendRequest` + response panel. Single working
  tab, no persistence yet (tabs/collections/history land in Fases E–G).
  """

  use TestFlowPhxWeb, :live_view

  alias TestFlowPhx.Domain.Request
  alias TestFlowPhx.UseCases.SendRequest
  alias TestFlowPhxWeb.RequestParams
  alias TestFlowPhxWeb.TesterComponents

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "TestFlow")
      |> assign(:active_request, initial_request())
      |> assign(:request_subtab, :params)
      |> assign(:response_subtab, :body)
      |> assign(:response, nil)
      |> assign(:in_flight?, false)
      |> assign(:sidebar_section, :collections)
      |> assign(:send_ref, nil)

    {:ok, socket}
  end

  defp initial_request do
    Request.new(
      method: "GET",
      url: "",
      query_params: [Request.empty_kv()],
      headers: [Request.empty_kv()],
      body_type: :none,
      body_text: "",
      auth: %{type: :none}
    )
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
        <form id="request-form" phx-change="update_request" phx-submit="send" class="space-y-4">
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

  # ---------- Events ----------

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

  def handle_event("update_request", %{"request" => params}, socket) do
    updated = RequestParams.from_form(params, socket.assigns.active_request)
    {:noreply, assign(socket, :active_request, updated)}
  end

  def handle_event("update_request", _params, socket), do: {:noreply, socket}

  def handle_event("add_kv_row", %{"field" => field}, socket)
      when field in ["query_params", "headers"] do
    key = String.to_existing_atom(field)
    request = socket.assigns.active_request
    rows = Map.fetch!(request, key) ++ [Request.empty_kv()]
    {:noreply, assign(socket, :active_request, Map.put(request, key, rows))}
  end

  def handle_event("remove_kv_row", %{"field" => field, "index" => idx_str}, socket)
      when field in ["query_params", "headers"] do
    key = String.to_existing_atom(field)
    idx = String.to_integer(idx_str)
    request = socket.assigns.active_request
    rows = Map.fetch!(request, key) |> List.delete_at(idx)
    rows = if rows == [], do: [Request.empty_kv()], else: rows
    {:noreply, assign(socket, :active_request, Map.put(request, key, rows))}
  end

  def handle_event("format_json", _params, socket) do
    request = socket.assigns.active_request

    case Jason.decode(request.body_text) do
      {:ok, parsed} ->
        pretty = parsed |> Jason.encode_to_iodata!(pretty: true) |> IO.iodata_to_binary()
        {:noreply, assign(socket, :active_request, %{request | body_text: pretty})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "JSON inválido — corrige antes de formatear.")}
    end
  end

  def handle_event("send", _params, socket) do
    if socket.assigns.in_flight? do
      {:noreply, socket}
    else
      request = socket.assigns.active_request

      task =
        Task.Supervisor.async_nolink(
          TestFlowPhx.TaskSupervisor,
          fn -> SendRequest.execute(request, record_history?: false) end
        )

      socket =
        socket
        |> assign(:in_flight?, true)
        |> assign(:response, nil)
        |> assign(:send_ref, task.ref)
        |> assign(:response_subtab, :body)

      {:noreply, socket}
    end
  end

  # ---------- Task results ----------

  @impl true
  def handle_info({ref, {response, _history}}, socket)
      when is_reference(ref) and ref == socket.assigns.send_ref do
    Process.demonitor(ref, [:flush])

    socket =
      socket
      |> assign(:in_flight?, false)
      |> assign(:response, response)
      |> assign(:send_ref, nil)

    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket)
      when is_reference(ref) and ref == socket.assigns.send_ref do
    error_response = %TestFlowPhx.Domain.Response{
      error: %{type: :unknown, message: "Task crashed: #{inspect(reason)}"}
    }

    socket =
      socket
      |> assign(:in_flight?, false)
      |> assign(:response, error_response)
      |> assign(:send_ref, nil)

    {:noreply, socket}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # ---------- helpers ----------

  defp sidebar_tab_class(active?) do
    base = "px-3 py-1.5 text-sm rounded-md transition-colors"

    if active? do
      base <> " bg-white border border-zinc-200 text-zinc-900 font-medium"
    else
      base <> " text-zinc-500 hover:text-zinc-800"
    end
  end
end
