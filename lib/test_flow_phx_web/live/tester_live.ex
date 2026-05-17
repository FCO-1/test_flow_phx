defmodule TestFlowPhxWeb.TesterLive do
  @moduledoc """
  Top-level LiveView for the REST endpoint tester.

  Fase E — multi-tab workspace. Each tab is a `%Request{}` with its own
  response slot and in-flight state. Tabs are persisted via
  `UseCases.Tabs` so a reload restores the workspace.
  """

  use TestFlowPhxWeb, :live_view

  alias TestFlowPhx.Domain.{Request, Response}
  alias TestFlowPhx.UseCases.{
    CollectionExport,
    CollectionImport,
    Collections,
    CurlExport,
    History,
    SendRequest,
    Settings,
    Tabs
  }
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
      |> assign(:collections, load_collections())
      |> assign(:expanded_collections, MapSet.new())
      |> assign(:editing_collection_id, nil)
      |> assign(:save_modal, nil)
      |> assign(:history, load_history())
      |> assign(:curl_copied?, false)
      |> assign(:theme, :system)
      |> assign(:density, :standard)
      |> assign(:settings_modal, nil)
      |> put_active_view()

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex h-screen w-screen dark:text-zinc-100 dark:bg-zinc-950" phx-window-keydown="hotkey">
      <div id="file-download-anchor" phx-hook="FileDownload" class="hidden"></div>
      <aside class="w-64 shrink-0 border-r border-zinc-200 dark:border-zinc-800 bg-zinc-50 dark:bg-zinc-900 p-3 overflow-y-auto flex flex-col">
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
        <div class="flex-1 min-h-0">
          <%= if @sidebar_section == :collections do %>
            <TesterComponents.collections_sidebar
              collections={@collections}
              expanded={@expanded_collections}
              editing_id={@editing_collection_id}
            />
          <% else %>
            <TesterComponents.history_sidebar history={@history} />
          <% end %>
        </div>
        <div class="pt-3 mt-3 border-t border-zinc-200 dark:border-zinc-800 flex flex-col gap-2 items-center">
          <TesterComponents.density_toggle density={@density} />
          <TesterComponents.theme_toggle theme={@theme} />
          <button
            type="button"
            phx-click="open_settings_modal"
            class="text-xs text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 px-2 py-1"
          >
            Settings
          </button>
        </div>
      </aside>

      <main class="flex-1 flex flex-col min-w-0 p-4 compact:p-2 fluid:p-6 gap-4 compact:gap-2 fluid:gap-6 overflow-hidden">
        <TesterComponents.tab_bar
          tabs={@tabs}
          active_id={@active_tab_id}
          in_flight_tabs={@in_flight_tabs}
        />

        <div class="flex-1 flex flex-col xl:flex-row gap-4 compact:gap-2 fluid:gap-6 min-h-0">
          <form
            id="request-form"
            phx-change="update_request"
            phx-submit="send"
            class="flex flex-col gap-4 compact:gap-2 fluid:gap-6 xl:w-1/2 xl:min-w-0 overflow-y-auto"
          >
            <input type="hidden" name="active_tab_id" value={@active_tab_id} />
            <TesterComponents.method_url_bar
              request={@active_request}
              in_flight?={@in_flight?}
              curl_copied?={@curl_copied?}
            />
            <TesterComponents.request_subtabs active={@request_subtab} />
            <div class="flex-1 min-h-[12rem] rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-4 compact:p-2 fluid:p-6">
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

          <div class="xl:w-1/2 xl:min-w-0 flex flex-col overflow-y-auto">
            <TesterComponents.response_panel
              response={@response}
              in_flight?={@in_flight?}
              active={@response_subtab}
            />
          </div>
        </div>
      </main>

      <TesterComponents.save_request_modal
        :if={@save_modal}
        state={@save_modal}
        collections={@collections}
      />

      <TesterComponents.settings_modal :if={@settings_modal} state={@settings_modal} />
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

  def handle_event("add_form_row", _params, socket) do
    socket =
      socket
      |> update_active_tab(fn req ->
        rows = (req.body_form || []) ++ [Request.empty_form_row()]
        %{req | body_form: rows}
      end)
      |> save_tabs()

    {:noreply, socket}
  end

  def handle_event("remove_form_row", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)

    socket =
      socket
      |> update_active_tab(fn req ->
        rows = req.body_form |> List.delete_at(idx)
        %{req | body_form: rows}
      end)
      |> save_tabs()

    {:noreply, socket}
  end

  def handle_event("add_kv_row", %{"field" => "body_form"}, socket) do
    handle_event("add_form_row", %{}, socket)
  end

  def handle_event("remove_kv_row", %{"field" => "body_form", "index" => idx}, socket) do
    handle_event("remove_form_row", %{"index" => idx}, socket)
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
          fn -> SendRequest.execute(request) end
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

  # ---------- Settings modal ----------

  def handle_event("open_settings_modal", _params, socket) do
    state = %{
      data_dir: Settings.get_data_dir(),
      default_dir: Settings.default_data_dir(),
      error: nil,
      flash: nil
    }

    {:noreply, assign(socket, :settings_modal, state)}
  end

  def handle_event("close_settings_modal", _params, socket) do
    {:noreply, assign(socket, :settings_modal, nil)}
  end

  def handle_event("update_settings_modal", %{"settings" => params}, socket) do
    case socket.assigns.settings_modal do
      nil ->
        {:noreply, socket}

      state ->
        new_state = %{state | data_dir: Map.get(params, "data_dir", state.data_dir)}
        {:noreply, assign(socket, :settings_modal, new_state)}
    end
  end

  def handle_event("commit_settings", %{"settings" => params}, socket) do
    state = socket.assigns.settings_modal || %{}
    typed = Map.get(params, "data_dir", "") |> String.trim()

    case Settings.set_data_dir(typed) do
      {:ok, applied} ->
        new_state = %{
          data_dir: applied,
          default_dir: Settings.default_data_dir(),
          error: nil,
          flash: "Carpeta de datos actualizada. Los próximos guardados irán a la nueva ruta."
        }

        socket =
          socket
          |> assign(:settings_modal, new_state)
          |> refresh_collections()
          |> refresh_history()

        {:noreply, socket}

      {:error, reason} ->
        new_state = %{state | error: Settings.format_error(reason), flash: nil}
        {:noreply, assign(socket, :settings_modal, new_state)}
    end
  end

  # ---------- Theme ----------

  def handle_event("theme:current", %{"theme" => t}, socket) do
    {:noreply, assign(socket, :theme, parse_theme(t))}
  end

  def handle_event("set_theme", %{"theme" => t}, socket) do
    theme = parse_theme(t)

    socket =
      socket
      |> assign(:theme, theme)
      |> push_event("theme:set", %{theme: Atom.to_string(theme)})

    {:noreply, socket}
  end

  # ---------- Density ----------

  def handle_event("density:current", %{"density" => d}, socket) do
    {:noreply, assign(socket, :density, parse_density(d))}
  end

  def handle_event("set_density", %{"density" => d}, socket) do
    density = parse_density(d)

    socket =
      socket
      |> assign(:density, density)
      |> push_event("density:set", %{density: Atom.to_string(density)})

    {:noreply, socket}
  end

  # ---------- Keyboard shortcuts ----------

  def handle_event("hotkey", params, socket) do
    case classify_hotkey(params) do
      :send ->
        if socket.assigns.in_flight? do
          {:noreply, socket}
        else
          handle_event("send", %{}, socket)
        end

      :new_tab ->
        handle_event("new_tab", %{}, socket)

      :close_tab ->
        handle_event("close_tab", %{"id" => socket.assigns.active_tab_id}, socket)

      :none ->
        {:noreply, socket}
    end
  end

  # ---------- Copy as cURL ----------

  def handle_event("copy_as_curl", _params, socket) do
    curl = CurlExport.from_request(socket.assigns.active_request)
    Process.send_after(self(), :clear_curl_copied, 1500)

    socket =
      socket
      |> assign(:curl_copied?, true)
      |> push_event("clipboard:copy", %{text: curl})

    {:noreply, socket}
  end

  # ---------- Collections sidebar ----------

  def handle_event("new_collection", %{"name" => name}, socket) do
    case String.trim(name) do
      "" ->
        {:noreply, socket}

      trimmed ->
        try_repo(fn -> Collections.create(trimmed) end)
        {:noreply, refresh_collections(socket)}
    end
  end

  def handle_event("toggle_collection", %{"id" => id}, socket) do
    expanded =
      if MapSet.member?(socket.assigns.expanded_collections, id) do
        MapSet.delete(socket.assigns.expanded_collections, id)
      else
        MapSet.put(socket.assigns.expanded_collections, id)
      end

    {:noreply, assign(socket, :expanded_collections, expanded)}
  end

  def handle_event("delete_collection", %{"id" => id}, socket) do
    try_repo(fn -> Collections.delete(id) end)

    socket =
      socket
      |> assign(:editing_collection_id, nil)
      |> update(:expanded_collections, &MapSet.delete(&1, id))
      |> refresh_collections()

    {:noreply, socket}
  end

  def handle_event("export_collection", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.collections, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      coll ->
        json = CollectionExport.to_json(coll)
        filename = CollectionExport.suggested_filename(coll.name)

        socket =
          push_event(socket, "download:file", %{
            filename: filename,
            content: json,
            mime: "application/json"
          })

        {:noreply, socket}
    end
  end

  def handle_event("export_all_collections", _params, socket) do
    case socket.assigns.collections do
      [] ->
        {:noreply, socket}

      colls ->
        json = CollectionExport.to_json(colls)

        socket =
          push_event(socket, "download:file", %{
            filename: CollectionExport.suggested_filename(nil),
            content: json,
            mime: "application/json"
          })

        {:noreply, socket}
    end
  end

  def handle_event("import:file", %{"content" => content}, socket) do
    case CollectionImport.import_all(content) do
      {:ok, count} ->
        socket =
          socket
          |> refresh_collections()
          |> put_flash(:info, "Importadas #{count} #{collection_word(count)}.")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, CollectionImport.format_error(reason))}
    end
  end

  def handle_event("import:error", %{"message" => msg}, socket) do
    {:noreply, put_flash(socket, :error, msg)}
  end

  def handle_event("clear_collections", _params, socket) do
    try_repo(fn -> Collections.clear() end)

    socket =
      socket
      |> assign(:editing_collection_id, nil)
      |> assign(:expanded_collections, MapSet.new())
      |> refresh_collections()

    {:noreply, socket}
  end

  def handle_event("start_rename_collection", %{"id" => id}, socket) do
    {:noreply, assign(socket, :editing_collection_id, id)}
  end

  def handle_event("cancel_rename_collection", _params, socket) do
    {:noreply, assign(socket, :editing_collection_id, nil)}
  end

  def handle_event("commit_rename_collection", %{"id" => id, "name" => name}, socket) do
    case String.trim(name) do
      "" ->
        {:noreply, assign(socket, :editing_collection_id, nil)}

      trimmed ->
        try_repo(fn -> Collections.rename(id, trimmed) end)

        socket =
          socket
          |> assign(:editing_collection_id, nil)
          |> refresh_collections()

        {:noreply, socket}
    end
  end

  def handle_event(
        "open_request_in_tab",
        %{"collection-id" => coll_id, "request-id" => req_id},
        socket
      ) do
    with %{} = coll <- Enum.find(socket.assigns.collections, &(&1.id == coll_id)),
         %Request{} = req <- Enum.find(coll.requests, &(&1.id == req_id)) do
      tab = %{req | id: Request.new_id()}

      socket =
        socket
        |> update(:tabs, &(&1 ++ [tab]))
        |> assign(:active_tab_id, tab.id)
        |> put_active_view()
        |> save_tabs()

      {:noreply, socket}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event(
        "delete_request_from_collection",
        %{"collection-id" => coll_id, "request-id" => req_id},
        socket
      ) do
    try_repo(fn -> Collections.remove_request(coll_id, req_id) end)
    {:noreply, refresh_collections(socket)}
  end

  # ---------- Save modal ----------

  def handle_event("open_save_modal", _params, socket) do
    target =
      case socket.assigns.collections do
        [first | _] -> first.id
        [] -> :new
      end

    state = %{
      name: default_request_name(socket.assigns.active_request),
      target: target,
      new_name: ""
    }

    {:noreply, assign(socket, :save_modal, state)}
  end

  def handle_event("close_save_modal", _params, socket) do
    {:noreply, assign(socket, :save_modal, nil)}
  end

  def handle_event("update_save_modal", %{"save" => params}, socket) do
    state = socket.assigns.save_modal || %{name: "", target: :new, new_name: ""}

    new_state = %{
      name: Map.get(params, "name", state.name),
      target: parse_save_target(Map.get(params, "target")),
      new_name: Map.get(params, "new_name", state.new_name)
    }

    {:noreply, assign(socket, :save_modal, new_state)}
  end

  def handle_event("commit_save", %{"save" => params}, socket) do
    name = String.trim(Map.get(params, "name", ""))
    target = parse_save_target(Map.get(params, "target"))
    new_name = String.trim(Map.get(params, "new_name", ""))

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "El nombre del request no puede estar vacío.")}

      target == :new and new_name == "" ->
        {:noreply, put_flash(socket, :error, "Indica un nombre para la nueva colección.")}

      true ->
        coll_id =
          case target do
            :new ->
              created = try_repo(fn -> Collections.create(new_name) end)
              if created, do: created.id, else: nil

            id when is_binary(id) ->
              id
          end

        if coll_id do
          base = socket.assigns.active_request
          req = %{base | id: Request.new_id(), name: name}
          try_repo(fn -> Collections.add_request(coll_id, req) end)

          socket =
            socket
            |> assign(:save_modal, nil)
            |> update(:expanded_collections, &MapSet.put(&1, coll_id))
            |> refresh_collections()
            |> put_flash(:info, "Request guardada en la colección.")

          {:noreply, socket}
        else
          {:noreply,
           put_flash(socket, :error, "No se pudo guardar (¿storage detenido?).")}
        end
    end
  end

  # ---------- History sidebar ----------

  def handle_event("open_history_in_tab", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.history, &(&1.id == id)) do
      %{request: %Request{} = req} when not is_nil(req) ->
        tab = %{req | id: Request.new_id()}

        socket =
          socket
          |> update(:tabs, &(&1 ++ [tab]))
          |> assign(:active_tab_id, tab.id)
          |> put_active_view()
          |> save_tabs()

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_history", _params, socket) do
    try_repo(fn -> History.clear() end)
    {:noreply, refresh_history(socket)}
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
          |> refresh_history()
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

  def handle_info(:clear_curl_copied, socket) do
    {:noreply, assign(socket, :curl_copied?, false)}
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

  defp load_collections do
    Collections.list()
  catch
    :exit, _ -> []
  end

  defp refresh_collections(socket), do: assign(socket, :collections, load_collections())

  defp load_history do
    History.list(50)
  catch
    :exit, _ -> []
  end

  defp refresh_history(socket), do: assign(socket, :history, load_history())

  defp try_repo(fun) do
    fun.()
  catch
    :exit, _ -> nil
  end

  defp collection_word(1), do: "colección"
  defp collection_word(_), do: "colecciones"

  defp parse_theme("light"), do: :light
  defp parse_theme("dark"), do: :dark
  defp parse_theme(_), do: :system

  defp parse_density("compact"), do: :compact
  defp parse_density("fluid"), do: :fluid
  defp parse_density(_), do: :standard

  defp classify_hotkey(%{"key" => key} = p) do
    ctrl_or_meta = truthy(p["ctrlKey"]) or truthy(p["metaKey"])
    alt = truthy(p["altKey"])

    cond do
      key == "Enter" and ctrl_or_meta -> :send
      alt and key in ["n", "N"] -> :new_tab
      alt and key in ["w", "W"] -> :close_tab
      true -> :none
    end
  end

  defp classify_hotkey(_), do: :none

  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false

  defp parse_save_target("new"), do: :new
  defp parse_save_target(nil), do: :new
  defp parse_save_target(""), do: :new
  defp parse_save_target(id) when is_binary(id), do: id

  defp default_request_name(%{name: name}) when name not in [nil, "", "Untitled"], do: name
  defp default_request_name(%{method: m, url: url}) when url != "", do: "#{m} #{url}"
  defp default_request_name(_), do: "New Request"

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
      base <> "bg-white dark:bg-zinc-900 dark:bg-zinc-800 border border-zinc-200 dark:border-zinc-700 text-zinc-900 dark:text-zinc-100 font-medium"
    else
      base <> "text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200"
    end
  end
end
