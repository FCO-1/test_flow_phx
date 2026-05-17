defmodule TestFlowPhxWeb.RestLive.Index do
  @moduledoc """
  Top-level LiveView for the REST endpoint tester.

  Lives under `live/rest_live/` so future protocols (GraphQL, WebSocket,
  gRPC) get their own folder with their own template and helpers —
  splitting the assigns and event surface per protocol keeps each view
  small and lets routes load only what they need.

  This module focuses on routing events to side-effects. Heavy lifting is
  delegated to:
    * `TabState`     — tab list / active view / send_refs bookkeeping
    * `RepoHelpers`  — collections/history load + refresh with :exit safety
    * `Hotkeys`      — keydown payload → action atom
    * `Parsers`      — small input parsers (theme, density, save_target, etc.)
    * `Styles`       — dynamic class lists used by the template
    * `index.html.heex` — the rendered template
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
    Settings
  }

  alias TestFlowPhxWeb.RequestParams
  alias TestFlowPhxWeb.TesterComponents
  alias TestFlowPhxWeb.RestLive.{Hotkeys, Parsers, RepoHelpers, Styles, TabState}

  # `render/1` is auto-discovered from the colocated `index.html.heex`.

  @impl true
  def mount(_params, _session, socket) do
    {tabs, active_id} = TabState.load_or_seed()

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
      |> assign(:collections, RepoHelpers.load_collections())
      |> assign(:expanded_collections, MapSet.new())
      |> assign(:editing_collection_id, nil)
      |> assign(:save_modal, nil)
      |> assign(:history, RepoHelpers.load_history())
      |> assign(:curl_copied?, false)
      |> assign(:theme, :system)
      |> assign(:density, :standard)
      |> assign(:settings_modal, nil)
      |> TabState.put_active_view()

    {:ok, socket}
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
        |> TabState.put_active_view()
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
      |> TabState.save()

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
            fresh = TabState.new_request()
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
          |> TabState.drop_send_refs_for(id)
          |> TabState.put_active_view()
          |> TabState.save()

        {:noreply, socket}
    end
  end

  # ---------- Request editing ----------

  def handle_event("update_request", %{"request" => params}, socket) do
    socket =
      socket
      |> TabState.update_active(fn req -> RequestParams.from_form(params, req) end)
      |> TabState.save()

    {:noreply, socket}
  end

  def handle_event("update_request", _params, socket), do: {:noreply, socket}

  def handle_event("add_kv_row", %{"field" => "body_form"}, socket) do
    handle_event("add_form_row", %{}, socket)
  end

  def handle_event("add_kv_row", %{"field" => field}, socket)
      when field in ["query_params", "headers"] do
    key = String.to_existing_atom(field)

    socket =
      socket
      |> TabState.update_active(fn req ->
        rows = Map.fetch!(req, key) ++ [Request.empty_kv()]
        Map.put(req, key, rows)
      end)
      |> TabState.save()

    {:noreply, socket}
  end

  def handle_event("add_form_row", _params, socket) do
    socket =
      socket
      |> TabState.update_active(fn req ->
        rows = (req.body_form || []) ++ [Request.empty_form_row()]
        %{req | body_form: rows}
      end)
      |> TabState.save()

    {:noreply, socket}
  end

  def handle_event("remove_form_row", %{"index" => idx_str}, socket) do
    idx = String.to_integer(idx_str)

    socket =
      socket
      |> TabState.update_active(fn req ->
        rows = req.body_form |> List.delete_at(idx)
        %{req | body_form: rows}
      end)
      |> TabState.save()

    {:noreply, socket}
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
      |> TabState.update_active(fn req ->
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
      |> TabState.save()

    {:noreply, socket}
  end

  def handle_event("format_json", _params, socket) do
    request = socket.assigns.active_request

    case Jason.decode(request.body_text) do
      {:ok, parsed} ->
        pretty = parsed |> Jason.encode_to_iodata!(pretty: true) |> IO.iodata_to_binary()

        socket =
          socket
          |> TabState.update_active(fn req -> %{req | body_text: pretty} end)
          |> TabState.save()

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
      socket =
        case params do
          %{"request" => form} ->
            TabState.update_active(socket, fn req -> RequestParams.from_form(form, req) end)

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
        |> TabState.put_active_view()
        |> TabState.save()

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
          |> RepoHelpers.refresh_collections()
          |> RepoHelpers.refresh_history()

        {:noreply, socket}

      {:error, reason} ->
        new_state = %{state | error: Settings.format_error(reason), flash: nil}
        {:noreply, assign(socket, :settings_modal, new_state)}
    end
  end

  # ---------- Theme / Density ----------

  def handle_event("theme:current", %{"theme" => t}, socket),
    do: {:noreply, assign(socket, :theme, Parsers.theme(t))}

  def handle_event("set_theme", %{"theme" => t}, socket) do
    theme = Parsers.theme(t)

    socket =
      socket
      |> assign(:theme, theme)
      |> push_event("theme:set", %{theme: Atom.to_string(theme)})

    {:noreply, socket}
  end

  def handle_event("density:current", %{"density" => d}, socket),
    do: {:noreply, assign(socket, :density, Parsers.density(d))}

  def handle_event("set_density", %{"density" => d}, socket) do
    density = Parsers.density(d)

    socket =
      socket
      |> assign(:density, density)
      |> push_event("density:set", %{density: Atom.to_string(density)})

    {:noreply, socket}
  end

  # ---------- Keyboard shortcuts ----------

  def handle_event("hotkey", params, socket) do
    case Hotkeys.classify(params) do
      :send ->
        if socket.assigns.in_flight?,
          do: {:noreply, socket},
          else: handle_event("send", %{}, socket)

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
        RepoHelpers.try_call(fn -> Collections.create(trimmed) end)
        {:noreply, RepoHelpers.refresh_collections(socket)}
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
    RepoHelpers.try_call(fn -> Collections.delete(id) end)

    socket =
      socket
      |> assign(:editing_collection_id, nil)
      |> update(:expanded_collections, &MapSet.delete(&1, id))
      |> RepoHelpers.refresh_collections()

    {:noreply, socket}
  end

  def handle_event("export_collection", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.collections, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      coll ->
        socket =
          push_event(socket, "download:file", %{
            filename: CollectionExport.suggested_filename(coll.name),
            content: CollectionExport.to_json(coll),
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
        socket =
          push_event(socket, "download:file", %{
            filename: CollectionExport.suggested_filename(nil),
            content: CollectionExport.to_json(colls),
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
          |> RepoHelpers.refresh_collections()
          |> put_flash(:info, "Importadas #{count} #{Parsers.collection_word(count)}.")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, CollectionImport.format_error(reason))}
    end
  end

  def handle_event("import:error", %{"message" => msg}, socket),
    do: {:noreply, put_flash(socket, :error, msg)}

  def handle_event("clear_collections", _params, socket) do
    RepoHelpers.try_call(fn -> Collections.clear() end)

    socket =
      socket
      |> assign(:editing_collection_id, nil)
      |> assign(:expanded_collections, MapSet.new())
      |> RepoHelpers.refresh_collections()

    {:noreply, socket}
  end

  def handle_event("start_rename_collection", %{"id" => id}, socket),
    do: {:noreply, assign(socket, :editing_collection_id, id)}

  def handle_event("cancel_rename_collection", _params, socket),
    do: {:noreply, assign(socket, :editing_collection_id, nil)}

  def handle_event("commit_rename_collection", %{"id" => id, "name" => name}, socket) do
    case String.trim(name) do
      "" ->
        {:noreply, assign(socket, :editing_collection_id, nil)}

      trimmed ->
        RepoHelpers.try_call(fn -> Collections.rename(id, trimmed) end)

        socket =
          socket
          |> assign(:editing_collection_id, nil)
          |> RepoHelpers.refresh_collections()

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
        |> TabState.put_active_view()
        |> TabState.save()

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
    RepoHelpers.try_call(fn -> Collections.remove_request(coll_id, req_id) end)
    {:noreply, RepoHelpers.refresh_collections(socket)}
  end

  # ---------- Save modal ----------

  def handle_event("open_save_modal", _params, socket) do
    target =
      case socket.assigns.collections do
        [first | _] -> first.id
        [] -> :new
      end

    state = %{
      name: Parsers.default_request_name(socket.assigns.active_request),
      target: target,
      new_name: ""
    }

    {:noreply, assign(socket, :save_modal, state)}
  end

  def handle_event("close_save_modal", _params, socket),
    do: {:noreply, assign(socket, :save_modal, nil)}

  def handle_event("update_save_modal", %{"save" => params}, socket) do
    state = socket.assigns.save_modal || %{name: "", target: :new, new_name: ""}

    new_state = %{
      name: Map.get(params, "name", state.name),
      target: Parsers.save_target(Map.get(params, "target")),
      new_name: Map.get(params, "new_name", state.new_name)
    }

    {:noreply, assign(socket, :save_modal, new_state)}
  end

  def handle_event("commit_save", %{"save" => params}, socket) do
    name = String.trim(Map.get(params, "name", ""))
    target = Parsers.save_target(Map.get(params, "target"))
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
              created = RepoHelpers.try_call(fn -> Collections.create(new_name) end)
              if created, do: created.id, else: nil

            id when is_binary(id) ->
              id
          end

        if coll_id do
          base = socket.assigns.active_request
          req = %{base | id: Request.new_id(), name: name}
          RepoHelpers.try_call(fn -> Collections.add_request(coll_id, req) end)

          socket =
            socket
            |> assign(:save_modal, nil)
            |> update(:expanded_collections, &MapSet.put(&1, coll_id))
            |> RepoHelpers.refresh_collections()
            |> put_flash(:info, "Request guardada en la colección.")

          {:noreply, socket}
        else
          {:noreply, put_flash(socket, :error, "No se pudo guardar (¿storage detenido?).")}
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
          |> TabState.put_active_view()
          |> TabState.save()

        {:noreply, socket}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_history", _params, socket) do
    RepoHelpers.try_call(fn -> History.clear() end)
    {:noreply, RepoHelpers.refresh_history(socket)}
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
          |> RepoHelpers.refresh_history()
          |> TabState.put_active_view()

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
          |> TabState.put_active_view()

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_info(:clear_curl_copied, socket),
    do: {:noreply, assign(socket, :curl_copied?, false)}

  def handle_info(_other, socket), do: {:noreply, socket}
end
