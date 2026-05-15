defmodule TestFlowPhxWeb.TesterComponents do
  @moduledoc """
  Function components for the REST tester UI.

  Stateless — each component receives the `%Request{}` / `%Response{}` it
  needs and emits events the parent LiveView handles.
  """

  use Phoenix.Component

  alias TestFlowPhx.Domain.{Request, Response}

  @methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)

  attr :request, Request, required: true
  attr :in_flight?, :boolean, default: false

  def method_url_bar(assigns) do
    assigns = assign(assigns, :methods, @methods)

    ~H"""
    <div class="flex gap-2 items-center">
      <select
        name="request[method]"
        class="rounded-md border border-zinc-300 px-3 py-2 font-mono text-sm bg-white"
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
        class="flex-1 rounded-md border border-zinc-300 px-3 py-2 font-mono text-sm"
      />
      <button
        type="submit"
        disabled={@in_flight?}
        class={[
          "rounded-md px-4 py-2 text-sm font-medium",
          if(@in_flight?,
            do: "bg-zinc-300 text-zinc-500 cursor-not-allowed",
            else: "bg-zinc-900 text-white hover:bg-zinc-700"
          )
        ]}
      >
        {if(@in_flight?, do: "Sending…", else: "Send")}
      </button>
    </div>
    """
  end

  attr :active, :atom, required: true

  def request_subtabs(assigns) do
    ~H"""
    <div class="flex gap-1 border-b border-zinc-200">
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
          class="rounded border-zinc-300"
        />
        <input
          type="text"
          name={"request[#{@field}][#{idx}][key]"}
          value={row.key}
          placeholder={@placeholder_key}
          phx-debounce="200"
          class="flex-1 rounded-md border border-zinc-300 px-2 py-1 font-mono text-sm"
        />
        <input
          type="text"
          name={"request[#{@field}][#{idx}][value]"}
          value={row.value}
          placeholder={@placeholder_value}
          phx-debounce="200"
          class="flex-1 rounded-md border border-zinc-300 px-2 py-1 font-mono text-sm"
        />
        <button
          type="button"
          phx-click="remove_kv_row"
          phx-value-field={@field}
          phx-value-index={idx}
          class="text-zinc-400 hover:text-red-600 px-2"
          aria-label="Remove row"
        >
          ×
        </button>
      </div>
      <button
        type="button"
        phx-click="add_kv_row"
        phx-value-field={@field}
        class="text-sm text-zinc-600 hover:text-zinc-900"
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
              class="w-full rounded-md border border-zinc-300 px-3 py-2 font-mono text-sm"
              placeholder={if @request.body_type == :json, do: ~s({"key":"value"}), else: "raw body"}
            >{@request.body_text}</textarea>
            <button
              :if={@request.body_type == :json}
              type="button"
              phx-click="format_json"
              class="absolute top-2 right-2 text-xs px-2 py-1 rounded bg-zinc-100 hover:bg-zinc-200"
            >
              Format
            </button>
          </div>

        <% @request.body_type == :form_urlencoded -> %>
          <p class="text-sm text-zinc-500 italic">Editor de form-urlencoded llega en Fase G.</p>

        <% @request.body_type == :multipart -> %>
          <p class="text-sm text-zinc-500 italic">Editor multipart llega en Fase G.</p>

        <% true -> %>
          <p class="text-sm text-zinc-500 italic">Sin body.</p>
      <% end %>
    </div>
    """
  end

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
            class="w-full rounded-md border border-zinc-300 px-3 py-2 font-mono text-sm"
          />

        <% :api_key -> %>
          <div class="space-y-2">
            <input
              type="text"
              name="request[auth][key]"
              value={Map.get(@request.auth, :key, "")}
              placeholder="header or query name (e.g. X-Api-Key)"
              phx-debounce="200"
              class="w-full rounded-md border border-zinc-300 px-3 py-2 font-mono text-sm"
            />
            <input
              type="text"
              name="request[auth][value]"
              value={Map.get(@request.auth, :value, "")}
              placeholder="value"
              phx-debounce="200"
              class="w-full rounded-md border border-zinc-300 px-3 py-2 font-mono text-sm"
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
          <p class="text-sm text-zinc-500 italic">Sin autenticación.</p>
      <% end %>
    </div>
    """
  end

  attr :response, :any, default: nil
  attr :in_flight?, :boolean, default: false
  attr :active, :atom, default: :body

  def response_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-zinc-200 bg-white">
      <%= cond do %>
        <% @in_flight? -> %>
          <div class="p-6">
            <p class="text-sm text-zinc-500 animate-pulse">Sending request…</p>
          </div>

        <% is_nil(@response) -> %>
          <div class="p-6">
            <p class="text-sm text-zinc-400">No response yet — click Send to fire a request.</p>
          </div>

        <% @response.error -> %>
          <div class="p-6 space-y-2">
            <p class="text-sm font-medium text-red-600">
              Error: <span class="font-mono">{@response.error.type}</span>
            </p>
            <p class="text-sm text-zinc-700 font-mono break-all">{@response.error.message}</p>
            <p class="text-xs text-zinc-500">Duration: {@response.duration_ms} ms</p>
          </div>

        <% true -> %>
          <header class="flex items-center justify-between px-4 py-2 border-b border-zinc-200">
            <div class="flex gap-3 items-center text-sm">
              <span class={status_pill_class(@response.status)}>{@response.status}</span>
              <span class="text-zinc-500">{@response.duration_ms} ms</span>
              <span class="text-zinc-500">{format_size(@response.size_bytes)}</span>
            </div>
          </header>
          <div class="flex gap-1 px-4 py-1 border-b border-zinc-200">
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
                  <pre class="text-xs font-mono whitespace-pre-wrap text-zinc-800">{pretty_json(@response.body_decoded)}</pre>
                <% else %>
                  <pre class="text-xs font-mono whitespace-pre-wrap text-zinc-800">{@response.body}</pre>
                <% end %>

              <% :headers -> %>
                <dl class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 text-xs font-mono">
                  <%= for {k, v} <- @response.headers do %>
                    <dt class="text-zinc-500">{k}</dt>
                    <dd class="text-zinc-800 break-all">{v}</dd>
                  <% end %>
                </dl>

              <% :raw -> %>
                <pre class="text-xs font-mono whitespace-pre-wrap text-zinc-800">{@response.body}</pre>
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
          do: "bg-zinc-100 text-zinc-900 font-medium",
          else: "text-zinc-500 hover:text-zinc-800"
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
        true -> "bg-zinc-100 text-zinc-700"
      end

    "inline-flex items-center rounded-md px-2 py-0.5 text-xs font-mono font-semibold " <>
      family
  end

  defp status_pill_class(_),
    do:
      "inline-flex items-center rounded-md px-2 py-0.5 text-xs font-mono font-semibold bg-zinc-100 text-zinc-700"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1024, do: "#{bytes} B"

  defp format_size(bytes) when is_integer(bytes) and bytes < 1_048_576 do
    "#{Float.round(bytes / 1024, 1)} KB"
  end

  defp format_size(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_size(_), do: "?"

  defp pretty_json(term) do
    term
    |> Jason.encode_to_iodata!(pretty: true)
    |> IO.iodata_to_binary()
  end

  # Discourage unused alias warnings while keeping the alias for typespecs.
  _ = Response
end
