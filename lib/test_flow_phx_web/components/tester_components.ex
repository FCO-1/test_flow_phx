defmodule TestFlowPhxWeb.TesterComponents do
  @moduledoc """
  Function components para la UI del tester REST.

  Sin estado — cada componente recibe el `%Request{}` / `%Response{}`
  que necesita y emite eventos que la LiveView padre maneja.
  """

  use Phoenix.Component

  alias TestFlowPhx.Domain.{Collection, Request, Response}
  alias TestFlowPhx.UseCases.Translations

  @methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)

  attr :tabs, :list, required: true
  attr :active_id, :string, default: nil
  attr :in_flight_tabs, :any, default: nil

  def tab_bar(assigns) do
    assigns =
      assign_new(assigns, :in_flight_tabs, fn -> MapSet.new() end)

    ~H"""
    <div class="flex items-end gap-0.5 border-b border-zinc-200 dark:border-zinc-800 overflow-x-auto">
      <div
        :for={tab <- @tabs}
        class={[
          "flex items-center rounded-t-md border-x border-t shrink-0",
          if(tab.id == @active_id,
            do: "bg-white dark:bg-zinc-900 border-zinc-300 dark:border-zinc-700 -mb-px",
            else: "bg-zinc-50 dark:bg-zinc-900 border-transparent hover:bg-zinc-100 dark:hover:bg-zinc-800 dark:bg-zinc-800"
          )
        ]}
      >
        <button
          type="button"
          phx-click="select_tab"
          phx-value-id={tab.id}
          class="flex items-center gap-2 px-3 py-1.5 text-sm"
          title={tab.url}
        >
          <span class={tab_method_class(tab.method)}>{tab.method}</span>
          <span class="truncate max-w-[12rem]">{tab_label(tab)}</span>
          <span :if={MapSet.member?(@in_flight_tabs, tab.id)} class="text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 animate-pulse">●</span>
        </button>
        <button
          type="button"
          phx-click="close_tab"
          phx-value-id={tab.id}
          aria-label="Close tab"
          title="Close tab (Alt+W)"
          class="px-2 py-1.5 text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 hover:text-red-600 text-sm"
        >×</button>
      </div>
      <button
        type="button"
        phx-click="new_tab"
        aria-label="New tab"
        title="New tab (Alt+N)"
        class="px-3 py-1.5 text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 text-sm shrink-0"
      >+</button>
    </div>
    """
  end

  attr :request, Request, required: true
  attr :in_flight?, :boolean, default: false
  attr :curl_copied?, :boolean, default: false

  def method_url_bar(assigns) do
    assigns = assign(assigns, :methods, @methods)

    ~H"""
    <div class="flex gap-2 items-center">
      <select
        name="request[method]"
        class="rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-2 font-mono text-sm bg-white dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
      >
        <option :for={m <- @methods} value={m} selected={m == @request.method}>{m}</option>
      </select>
      <input
        type="text"
        name="request[url]"
        value={@request.url}
        placeholder="https://api.example.com/endpoint"
        phx-debounce="200"
        autocomplete="off"
        class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-2 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
      />
      <button
        type="button"
        phx-click="open_save_modal"
        class="rounded-md px-3 py-2 text-sm font-medium border border-zinc-300 dark:border-zinc-700 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-800 dark:bg-zinc-900"
      >
        Save
      </button>
      <button
        id="copy-curl-btn"
        type="button"
        phx-hook="ClipboardCopy"
        phx-click="copy_as_curl"
        title="Copy as cURL"
        class="rounded-md px-3 py-2 text-sm font-medium border border-zinc-300 dark:border-zinc-700 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-800 dark:bg-zinc-900"
      >
        {if(@curl_copied?, do: "Copied!", else: "cURL")}
      </button>
      <button
        type="submit"
        disabled={@in_flight?}
        title="Send (Ctrl/⌘+Enter)"
        class={[
          "rounded-md px-4 py-2 text-sm font-medium",
          if(@in_flight?,
            do: "bg-zinc-300 text-zinc-500 dark:text-zinc-400 cursor-not-allowed",
            else: "bg-zinc-900 text-white hover:bg-zinc-700"
          )
        ]}
      >
        {if(@in_flight?, do: "Sending…", else: "Send")}
      </button>
    </div>
    """
  end

  attr :density, :atom, required: true

  def density_toggle(assigns) do
    ~H"""
    <div
      id="density-toggle"
      phx-hook="DensityToggle"
      class="flex items-center gap-1 rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-0.5 text-xs"
    >
      <button
        :for={{value, label, title} <- [
          {:compact, "▬", "Compact"},
          {:standard, "≡", "Standard"},
          {:fluid, "☰", "Fluid"}
        ]}
        type="button"
        phx-click="set_density"
        phx-value-density={Atom.to_string(value)}
        title={title}
        class={[
          "px-2 py-1 rounded transition-colors",
          if(@density == value,
            do: "bg-zinc-900 text-white dark:bg-zinc-200 dark:text-zinc-900",
            else: "text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100"
          )
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :theme, :atom, required: true

  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      phx-hook="ThemeToggle"
      class="flex items-center gap-1 rounded-md border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900 p-0.5 text-xs"
    >
      <button
        :for={{value, label, title} <- [
          {:light, "☀", "Light"},
          {:system, "⌂", "System"},
          {:dark, "☾", "Dark"}
        ]}
        type="button"
        phx-click="set_theme"
        phx-value-theme={Atom.to_string(value)}
        title={title}
        class={[
          "px-2 py-1 rounded transition-colors",
          if(@theme == value,
            do: "bg-zinc-900 text-white dark:bg-zinc-200 dark:text-zinc-900",
            else: "text-zinc-500 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 dark:text-zinc-500"
          )
        ]}
      >
        {label}
      </button>
    </div>
    """
  end

  attr :collections, :list, required: true
  attr :expanded, :any, required: true
  attr :editing_id, :string, default: nil

  def collections_sidebar(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex items-center justify-between">
        <h3 class="text-xs uppercase tracking-wide text-zinc-500 dark:text-zinc-400 px-1">Saved</h3>
        <div class="flex items-center gap-2">
          <label
            for="import-file-input"
            title="Importar colección"
            class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100 px-1 cursor-pointer"
          >
            Import
          </label>
          <input
            id="import-file-input"
            type="file"
            accept="application/json,.json"
            phx-hook="FileImport"
            class="hidden"
          />
          <button
            :if={@collections != []}
            type="button"
            phx-click="export_all_collections"
            class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-zinc-900 dark:hover:text-zinc-100 px-1"
          >
            Export all
          </button>
          <button
            :if={@collections != []}
            type="button"
            phx-click="clear_collections"
            data-confirm="¿Borrar todas las colecciones? Esta acción no se puede deshacer."
            class="text-xs text-zinc-400 dark:text-zinc-500 hover:text-red-600 px-1"
          >
            Clear
          </button>
        </div>
      </div>

      <form phx-submit="new_collection" class="flex gap-1">
        <input
          type="text"
          name="name"
          placeholder="+ New collection"
          autocomplete="off"
          class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 text-xs dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
        />
      </form>

      <p :if={@collections == []} class="text-xs text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 px-1 py-2 italic">
        Sin colecciones todavía.
      </p>

      <ul class="space-y-1">
        <li :for={c <- @collections} class="text-sm">
          <div class={[
            "flex items-center gap-1 rounded px-1 py-0.5 group",
            "hover:bg-zinc-100 dark:hover:bg-zinc-800 dark:bg-zinc-800"
          ]}>
            <button
              type="button"
              phx-click="toggle_collection"
              phx-value-id={c.id}
              class="text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 w-4 text-xs"
              aria-label="Toggle collection"
            >{if(MapSet.member?(@expanded, c.id), do: "▼", else: "▶")}</button>

            <%= if @editing_id == c.id do %>
              <form
                phx-submit="commit_rename_collection"
                phx-value-id={c.id}
                class="flex-1"
              >
                <input
                  type="text"
                  name="name"
                  value={c.name}
                  autocomplete="off"
                  phx-blur="cancel_rename_collection"
                  phx-key="Escape"
                  phx-keydown="cancel_rename_collection"
                  class="w-full rounded border border-zinc-300 dark:border-zinc-700 px-1 py-0.5 text-xs dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
                  id={"rename-input-" <> c.id}
                  phx-mounted={Phoenix.LiveView.JS.focus()}
                />
              </form>
            <% else %>
              <button
                type="button"
                phx-click="start_rename_collection"
                phx-value-id={c.id}
                class="flex-1 text-left truncate"
                title={"Rename " <> c.name}
              >{c.name}</button>
            <% end %>

            <span class="text-xs text-zinc-400 dark:text-zinc-500 dark:text-zinc-400">{length(c.requests)}</span>

            <button
              type="button"
              phx-click="export_collection"
              phx-value-id={c.id}
              aria-label="Export collection"
              title="Export"
              class="text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100 px-1 invisible group-hover:visible text-xs"
            >↓</button>
            <button
              type="button"
              phx-click="delete_collection"
              phx-value-id={c.id}
              aria-label="Delete collection"
              class="text-zinc-300 hover:text-red-600 px-1 invisible group-hover:visible"
              data-confirm={"¿Borrar la colección \"" <> c.name <> "\"?"}
            >×</button>
          </div>

          <ul :if={MapSet.member?(@expanded, c.id)} class="pl-6 space-y-0.5 mt-1">
            <li :if={c.requests == []} class="text-xs text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 italic py-1">
              (vacía)
            </li>
            <li :for={r <- c.requests} class="flex items-center gap-1 group">
              <button
                type="button"
                phx-click="open_request_in_tab"
                phx-value-collection-id={c.id}
                phx-value-request-id={r.id}
                class="flex-1 flex items-center gap-2 text-left text-xs rounded px-1 py-0.5 hover:bg-zinc-100 dark:hover:bg-zinc-800 dark:bg-zinc-800"
              >
                <span class={tab_method_class(r.method)}>{r.method}</span>
                <span class="truncate">{request_label(r)}</span>
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

  attr :history, :list, required: true

  def history_sidebar(assigns) do
    ~H"""
    <div class="space-y-2">
      <div class="flex items-center justify-between">
        <h3 class="text-xs uppercase tracking-wide text-zinc-500 dark:text-zinc-400 px-1">Recent</h3>
        <button
          :if={@history != []}
          type="button"
          phx-click="clear_history"
          data-confirm="¿Borrar todo el historial?"
          class="text-xs text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 hover:text-red-600 px-1"
        >
          Clear
        </button>
      </div>

      <p :if={@history == []} class="text-xs text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 px-1 py-2 italic">
        Sin historial todavía. Envía un request para verlo aquí.
      </p>

      <ul class="space-y-0.5">
        <li :for={h <- @history} class="group">
          <button
            type="button"
            phx-click="open_history_in_tab"
            phx-value-id={h.id}
            class="w-full text-left rounded px-1 py-1 hover:bg-zinc-100 dark:hover:bg-zinc-800 dark:bg-zinc-800 flex flex-col gap-0.5"
          >
            <div class="flex items-center gap-2 text-xs">
              <span class={tab_method_class((h.request || %{method: "?"}).method)}>
                {(h.request || %{method: "?"}).method}
              </span>
              <span class={history_status_class(h.response_status, h.response_error)}>
                {history_status_label(h.response_status, h.response_error)}
              </span>
              <span class="text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 ml-auto">{h.response_duration_ms} ms</span>
            </div>
            <div class="text-xs text-zinc-700 dark:text-zinc-300 truncate font-mono">
              {(h.request || %{url: ""}).url}
            </div>
            <div class="text-[10px] text-zinc-400 dark:text-zinc-500 dark:text-zinc-400">{format_ran_at(h.ran_at)}</div>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  attr :state, :map, required: true
  attr :collections, :list, required: true

  def save_request_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/40">
      <div
        class="bg-white dark:bg-zinc-900 rounded-lg shadow-xl w-full max-w-md p-5"
        phx-click-away="close_save_modal"
        phx-window-keydown="close_save_modal"
        phx-key="Escape"
      >
        <h2 class="text-base font-semibold text-zinc-800 dark:text-zinc-200 mb-3">Guardar request</h2>

        <form
          id="save-request-form"
          phx-change="update_save_modal"
          phx-submit="commit_save"
          class="space-y-3"
        >
          <div>
            <label class="block text-xs text-zinc-500 dark:text-zinc-400 mb-1">Nombre</label>
            <input
              type="text"
              name="save[name]"
              value={@state.name}
              autocomplete="off"
              phx-debounce="200"
              autofocus
              class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1.5 text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
            />
          </div>

          <div>
            <label class="block text-xs text-zinc-500 dark:text-zinc-400 mb-1">Colección</label>
            <div class="space-y-1 max-h-40 overflow-y-auto rounded border border-zinc-200 dark:border-zinc-800 p-2">
              <label
                :for={c <- @collections}
                class="flex items-center gap-2 text-sm cursor-pointer"
              >
                <input
                  type="radio"
                  name="save[target]"
                  value={c.id}
                  checked={@state.target == c.id}
                />
                <span class="truncate">{c.name}</span>
                <span class="text-xs text-zinc-400 dark:text-zinc-500 dark:text-zinc-400">({length(c.requests)})</span>
              </label>
              <label class="flex items-center gap-2 text-sm cursor-pointer">
                <input
                  type="radio"
                  name="save[target]"
                  value="new"
                  checked={@state.target == :new}
                />
                <em>+ Nueva colección</em>
              </label>
            </div>
          </div>

          <div :if={@state.target == :new}>
            <label class="block text-xs text-zinc-500 dark:text-zinc-400 mb-1">Nombre de la colección</label>
            <input
              type="text"
              name="save[new_name]"
              value={@state.new_name}
              autocomplete="off"
              phx-debounce="200"
              class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1.5 text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
            />
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <button
              type="button"
              phx-click="close_save_modal"
              class="rounded-md px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-800 dark:bg-zinc-900"
            >
              Cancelar
            </button>
            <button
              type="submit"
              class="rounded-md px-3 py-1.5 text-sm bg-zinc-900 text-white hover:bg-zinc-700"
            >
              Guardar
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :state, :map, required: true

  def settings_modal(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center bg-zinc-900/40">
      <div
        class="bg-white dark:bg-zinc-900 rounded-lg shadow-xl w-full max-w-lg p-5"
        phx-click-away="close_settings_modal"
        phx-window-keydown="close_settings_modal"
        phx-key="Escape"
      >
        <h2 class="text-base font-semibold text-zinc-800 dark:text-zinc-200 mb-3">
          {Translations.t(@state.locale, "settings_modal.title")}
        </h2>

        <form
          id="settings-form"
          phx-change="update_settings_modal"
          phx-submit="commit_settings"
          class="space-y-3"
        >
          <div>
            <label class="block text-xs text-zinc-500 dark:text-zinc-400 mb-1">
              {Translations.t(@state.locale, "settings_modal.data_dir_label")}
            </label>
            <input
              type="text"
              name="settings[data_dir]"
              value={@state.data_dir}
              autocomplete="off"
              autofocus
              spellcheck="false"
              class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1.5 text-sm font-mono dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
              placeholder={@state.default_dir}
            />
            <p class="text-xs text-zinc-500 dark:text-zinc-400 mt-1">
              {Translations.t(@state.locale, "settings_modal.data_dir_help")}
              <code class="font-mono">{@state.default_dir}</code>
            </p>
          </div>

          <div>
            <label class="block text-xs text-zinc-500 dark:text-zinc-400 mb-1">
              {Translations.t(@state.locale, "settings_modal.language_label")}
            </label>
            <div class="flex flex-col gap-1">
              <label
                :for={loc <- @state.available_locales}
                class="flex items-center gap-2 text-sm cursor-pointer"
              >
                <input
                  type="radio"
                  name="settings[locale]"
                  value={loc}
                  checked={@state.locale == loc}
                />
                <span>{Translations.t(@state.locale, "languages." <> loc)}</span>
                <code class="text-xs text-zinc-400 dark:text-zinc-500 font-mono">{loc}</code>
              </label>
            </div>
          </div>

          <div
            :if={@state.error}
            class="rounded-md border border-red-300 dark:border-red-800 bg-red-50 dark:bg-red-900/20 px-3 py-2 text-sm text-red-800 dark:text-red-200"
          >
            {@state.error}
          </div>

          <div
            :if={@state.flash}
            class="rounded-md border border-emerald-300 dark:border-emerald-800 bg-emerald-50 dark:bg-emerald-900/20 px-3 py-2 text-sm text-emerald-800 dark:text-emerald-200"
          >
            {@state.flash}
          </div>

          <div class="flex justify-end gap-2 pt-2">
            <button
              type="button"
              phx-click="close_settings_modal"
              class="rounded-md px-3 py-1.5 text-sm border border-zinc-300 dark:border-zinc-700 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-800 dark:bg-zinc-900"
            >
              {Translations.t(@state.locale, "settings_modal.close")}
            </button>
            <button
              type="submit"
              class="rounded-md px-3 py-1.5 text-sm bg-zinc-900 text-white hover:bg-zinc-700"
            >
              {Translations.t(@state.locale, "settings_modal.apply")}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr :active, :atom, required: true

  def request_subtabs(assigns) do
    ~H"""
    <div class="flex gap-1 border-b border-zinc-200 dark:border-zinc-800">
      <.subtab
        :for={{label, key} <- [
          {"Params", :params},
          {"Headers", :headers},
          {"Body", :body},
          {"Auth", :auth}
        ]}
        label={label}
        active?={@active == key}
        click_event="set_request_subtab"
        click_value={Atom.to_string(key)}
      />
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :field, :string, required: true
  attr :placeholder_key, :string, default: "key"
  attr :placeholder_value, :string, default: "value"

  def kv_editor(assigns) do
    ~H"""
    <div class="space-y-2">
      <div :for={{row, idx} <- Enum.with_index(@rows)} class="flex gap-2 items-center">
        <input type="hidden" name={"request[#{@field}][#{idx}][enabled]"} value="false" />
        <input
          type="checkbox"
          name={"request[#{@field}][#{idx}][enabled]"}
          value="true"
          checked={row.enabled}
          class="rounded border-zinc-300 dark:border-zinc-700"
        />
        <input
          type="text"
          name={"request[#{@field}][#{idx}][key]"}
          value={row.key}
          placeholder={@placeholder_key}
          phx-debounce="200"
          class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
        />
        <input
          type="text"
          name={"request[#{@field}][#{idx}][value]"}
          value={row.value}
          placeholder={@placeholder_value}
          phx-debounce="200"
          class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
        />
        <button
          type="button"
          phx-click="remove_kv_row"
          phx-value-field={@field}
          phx-value-index={idx}
          class="text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 hover:text-red-600 px-2"
          aria-label="Remove row"
        >
          ×
        </button>
      </div>
      <button
        type="button"
        phx-click="add_kv_row"
        phx-value-field={@field}
        class="text-sm text-zinc-600 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100"
      >
        + Add row
      </button>
    </div>
    """
  end

  attr :request, Request, required: true

  def body_editor(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex gap-4 items-center">
        <label :for={{label, value} <- [
          {"None", "none"},
          {"JSON", "json"},
          {"Raw", "raw"},
          {"form-urlencoded", "form_urlencoded"},
          {"Multipart", "multipart"}
        ]} class="flex items-center gap-1.5 text-sm cursor-pointer">
          <input
            type="radio"
            name="request[body_type]"
            value={value}
            checked={@request.body_type == String.to_existing_atom(value)}
          />
          {label}
        </label>
      </div>

      <%= cond do %>
        <% @request.body_type in [:json, :raw] -> %>
          <div class="relative">
            <textarea
              name="request[body_text]"
              rows="10"
              phx-debounce="200"
              class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-2 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
              placeholder={if @request.body_type == :json, do: ~s({"key":"value"}), else: "raw body"}
            >{@request.body_text}</textarea>
            <button
              :if={@request.body_type == :json}
              type="button"
              phx-click="format_json"
              class="absolute top-2 right-2 text-xs px-2 py-1 rounded bg-zinc-100 dark:bg-zinc-700 text-zinc-800 dark:text-zinc-100 hover:bg-zinc-200 dark:hover:bg-zinc-600"
            >
              Format
            </button>
          </div>

        <% @request.body_type == :form_urlencoded -> %>
          <.kv_editor rows={form_text_rows(@request.body_form)} field="body_form" />

        <% @request.body_type == :multipart -> %>
          <.multipart_editor rows={@request.body_form} />

        <% true -> %>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 italic">Sin body.</p>
      <% end %>
    </div>
    """
  end

  attr :rows, :list, required: true

  def multipart_editor(assigns) do
    ~H"""
    <div class="space-y-2">
      <p class="text-xs text-zinc-500 dark:text-zinc-400 italic">
        Los archivos se leen del disco en cada envío — escribe la ruta absoluta.
      </p>

      <div :for={{row, idx} <- Enum.with_index(@rows)} class="flex gap-2 items-center">
        <input type="hidden" name={"request[body_form][#{idx}][enabled]"} value="false" />
        <input
          type="checkbox"
          name={"request[body_form][#{idx}][enabled]"}
          value="true"
          checked={row.enabled}
          class="rounded border-zinc-300 dark:border-zinc-700"
        />
        <input
          type="text"
          name={"request[body_form][#{idx}][key]"}
          value={row.key}
          placeholder="field-name"
          phx-debounce="200"
          class="w-32 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
        />
        <select
          name={"request[body_form][#{idx}][type]"}
          class="rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 text-sm bg-white dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
        >
          <option value="text" selected={row.type == :text}>Text</option>
          <option value="file" selected={row.type == :file}>File</option>
        </select>

        <%= if row.type == :file do %>
          <input
            type="text"
            name={"request[body_form][#{idx}][file_path]"}
            value={row.file_path || ""}
            placeholder="/absolute/path/to/file"
            phx-debounce="200"
            class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
          />
        <% else %>
          <input
            type="text"
            name={"request[body_form][#{idx}][value]"}
            value={row.value}
            placeholder="value"
            phx-debounce="200"
            class="flex-1 rounded-md border border-zinc-300 dark:border-zinc-700 px-2 py-1 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
          />
        <% end %>

        <button
          type="button"
          phx-click="remove_form_row"
          phx-value-index={idx}
          class="text-zinc-400 dark:text-zinc-500 dark:text-zinc-400 hover:text-red-600 px-2"
          aria-label="Remove row"
        >×</button>
      </div>

      <button
        type="button"
        phx-click="add_form_row"
        class="text-sm text-zinc-600 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100"
      >
        + Add row
      </button>
    </div>
    """
  end

  defp form_text_rows(rows) when is_list(rows) do
    Enum.map(rows, fn r ->
      %{key: r.key, value: r.value, enabled: r.enabled}
    end)
  end

  defp form_text_rows(_), do: []

  attr :request, Request, required: true

  def auth_editor(assigns) do
    ~H"""
    <div class="space-y-3">
      <div class="flex gap-4 items-center">
        <label :for={{label, value} <- [
          {"None", "none"},
          {"Bearer", "bearer"},
          {"API Key", "api_key"}
        ]} class="flex items-center gap-1.5 text-sm cursor-pointer">
          <input
            type="radio"
            name="request[auth][type]"
            value={value}
            checked={@request.auth.type == String.to_existing_atom(value)}
          />
          {label}
        </label>
      </div>

      <%= case @request.auth.type do %>
        <% :bearer -> %>
          <input
            type="text"
            name="request[auth][token]"
            value={Map.get(@request.auth, :token, "")}
            placeholder="token"
            phx-debounce="200"
            class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-2 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
          />

        <% :api_key -> %>
          <div class="space-y-2">
            <input
              type="text"
              name="request[auth][key]"
              value={Map.get(@request.auth, :key, "")}
              placeholder="header or query name (e.g. X-Api-Key)"
              phx-debounce="200"
              class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-2 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
            />
            <input
              type="text"
              name="request[auth][value]"
              value={Map.get(@request.auth, :value, "")}
              placeholder="value"
              phx-debounce="200"
              class="w-full rounded-md border border-zinc-300 dark:border-zinc-700 px-3 py-2 font-mono text-sm dark:bg-zinc-800 dark:text-zinc-100 dark:placeholder:text-zinc-500"
            />
            <div class="flex gap-3 text-sm">
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="radio"
                  name="request[auth][in]"
                  value="header"
                  checked={Map.get(@request.auth, :in) == :header}
                />
                Header
              </label>
              <label class="flex items-center gap-1.5 cursor-pointer">
                <input
                  type="radio"
                  name="request[auth][in]"
                  value="query"
                  checked={Map.get(@request.auth, :in) == :query}
                />
                Query
              </label>
            </div>
          </div>

        <% _ -> %>
          <p class="text-sm text-zinc-500 dark:text-zinc-400 italic">Sin autenticación.</p>
      <% end %>
    </div>
    """
  end

  attr :response, :any, default: nil
  attr :in_flight?, :boolean, default: false
  attr :active, :atom, default: :body

  def response_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900">
      <%= cond do %>
        <% @in_flight? -> %>
          <div class="p-6">
            <p class="text-sm text-zinc-500 dark:text-zinc-400 animate-pulse">Sending request…</p>
          </div>

        <% is_nil(@response) -> %>
          <div class="p-6">
            <p class="text-sm text-zinc-400 dark:text-zinc-500 dark:text-zinc-400">No response yet — click Send to fire a request.</p>
          </div>

        <% @response.error -> %>
          <div class="p-6 space-y-2">
            <p class="text-sm font-medium text-red-600">
              Error: <span class="font-mono">{@response.error.type}</span>
            </p>
            <p class="text-sm text-zinc-700 dark:text-zinc-300 font-mono break-all">{@response.error.message}</p>
            <p class="text-xs text-zinc-500 dark:text-zinc-400">Duration: {@response.duration_ms} ms</p>
          </div>

        <% true -> %>
          <header class="flex items-center justify-between px-4 py-2 border-b border-zinc-200 dark:border-zinc-800">
            <div class="flex gap-3 items-center text-sm">
              <span class={status_pill_class(@response.status)}>{@response.status}</span>
              <span class="text-zinc-500 dark:text-zinc-400">{@response.duration_ms} ms</span>
              <span class="text-zinc-500 dark:text-zinc-400">{format_size(@response.size_bytes)}</span>
            </div>
          </header>
          <div class="flex gap-1 px-4 py-1 border-b border-zinc-200 dark:border-zinc-800">
            <.subtab
              :for={{label, key} <- [{"Body", :body}, {"Headers", :headers}, {"Raw", :raw}]}
              label={label}
              active?={@active == key}
              click_event="set_response_subtab"
              click_value={Atom.to_string(key)}
            />
          </div>
          <div class="p-4 overflow-auto max-h-96">
            <%= case @active do %>
              <% :body -> %>
                <%= if @response.body_decoded do %>
                  <pre class="text-xs font-mono whitespace-pre-wrap text-zinc-800 dark:text-zinc-200">{pretty_json(@response.body_decoded)}</pre>
                <% else %>
                  <pre class="text-xs font-mono whitespace-pre-wrap text-zinc-800 dark:text-zinc-200">{@response.body}</pre>
                <% end %>

              <% :headers -> %>
                <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-xs font-mono">
                  <%= for {k, v} <- @response.headers do %>
                    <dt class="text-zinc-500 dark:text-zinc-400">{k}</dt>
                    <dd class="text-zinc-800 dark:text-zinc-200 break-all">{v}</dd>
                  <% end %>
                </dl>

              <% :raw -> %>
                <pre class="text-xs font-mono whitespace-pre-wrap text-zinc-800 dark:text-zinc-200">{@response.body}</pre>
            <% end %>
          </div>
      <% end %>
    </div>
    """
  end

  # ---------- private helpers ----------

  attr :label, :string, required: true
  attr :active?, :boolean, required: true
  attr :click_event, :string, required: true
  attr :click_value, :string, required: true

  defp subtab(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@click_event}
      phx-value-subtab={@click_value}
      class={[
        "px-3 py-1.5 text-sm rounded-md transition-colors",
        if(@active?,
          do: "bg-zinc-100 dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 font-medium",
          else: "text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  defp status_pill_class(status) when is_integer(status) do
    family =
      cond do
        status >= 200 and status < 300 -> "bg-emerald-100 text-emerald-700"
        status >= 300 and status < 400 -> "bg-sky-100 text-sky-700"
        status >= 400 and status < 500 -> "bg-amber-100 text-amber-700"
        status >= 500 -> "bg-red-100 text-red-700"
        true -> "bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300"
      end

    "inline-flex items-center rounded-md px-2 py-0.5 text-xs font-mono font-semibold " <>
      family
  end

  defp status_pill_class(_),
    do:
      "inline-flex items-center rounded-md px-2 py-0.5 text-xs font-mono font-semibold bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_size(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_size(_), do: "?"

  defp tab_label(%{name: name, url: url}) do
    cond do
      is_binary(name) and name not in ["", "Untitled"] -> name
      is_binary(url) and url != "" -> url
      true -> "Untitled"
    end
  end

  defp history_status_label(_, %{type: t}) when not is_nil(t), do: "ERR"
  defp history_status_label(status, _) when is_integer(status), do: Integer.to_string(status)
  defp history_status_label(_, _), do: "?"

  defp history_status_class(_, %{type: _}),
    do: "inline-flex items-center rounded-md px-1.5 text-[10px] font-mono font-semibold bg-red-100 text-red-700"

  defp history_status_class(status, _) when is_integer(status),
    do: status_pill_class(status) |> String.replace("px-2 py-0.5 text-xs", "px-1.5 text-[10px]")

  defp history_status_class(_, _),
    do: "inline-flex items-center rounded-md px-1.5 text-[10px] font-mono font-semibold bg-zinc-100 dark:bg-zinc-800 text-zinc-700 dark:text-zinc-300"

  defp format_ran_at(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "hace #{diff}s"
      diff < 3_600 -> "hace #{div(diff, 60)}min"
      diff < 86_400 -> "hace #{div(diff, 3_600)}h"
      true -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
    end
  end

  defp format_ran_at(_), do: ""

  defp request_label(%{name: name, url: url}) do
    cond do
      is_binary(name) and name not in ["", "Untitled"] -> name
      is_binary(url) and url != "" -> url
      true -> "Untitled"
    end
  end

  # Discourage unused alias warnings while keeping aliases for typespecs.
  _ = Collection

  defp tab_method_class(method) do
    family =
      case method do
        "GET" -> "text-emerald-700"
        "POST" -> "text-sky-700"
        "PUT" -> "text-amber-700"
        "PATCH" -> "text-violet-700"
        "DELETE" -> "text-red-700"
        _ -> "text-zinc-700 dark:text-zinc-300"
      end

    "text-xs font-mono font-bold " <> family
  end

  defp pretty_json(term) do
    term
    |> Jason.encode_to_iodata!(pretty: true)
    |> IO.iodata_to_binary()
  end

  # Discourage unused alias warnings while keeping the alias for typespecs.
  _ = Response
end
