defmodule TestFlowPhxWeb.TesterLive do
  @moduledoc """
  Top-level LiveView for the REST endpoint tester.

  Phase C: just the shell + assigns. The request panel, tab bar,
  collections sidebar and response panel come in later phases.
  """

  use TestFlowPhxWeb, :live_view

  alias TestFlowPhx.Domain.Request

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "TestFlow")
      |> assign(:active_request, Request.new(method: "GET", url: ""))
      |> assign(:response, nil)
      |> assign(:in_flight?, false)
      |> assign(:sidebar_section, :collections)

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

      <main class="flex-1 flex flex-col min-w-0 p-4 gap-4">
        <header>
          <h1 class="text-xl font-semibold text-zinc-800">TestFlow</h1>
          <p class="text-sm text-zinc-500">
            Probador local de endpoints REST · Fase C skeleton
          </p>
        </header>

        <section class="rounded-lg border border-zinc-200 bg-white p-6">
          <p class="text-sm text-zinc-600">
            El panel de petición aparece en Fase D. Por ahora la LiveView solo
            está montada para verificar el routing y los assigns.
          </p>
          <dl class="mt-4 grid grid-cols-[8rem_1fr] gap-y-1 text-sm">
            <dt class="text-zinc-500">method</dt>
            <dd class="font-mono">{@active_request.method}</dd>
            <dt class="text-zinc-500">url</dt>
            <dd class="font-mono">{@active_request.url || "—"}</dd>
            <dt class="text-zinc-500">in_flight?</dt>
            <dd class="font-mono">{@in_flight?}</dd>
            <dt class="text-zinc-500">sidebar</dt>
            <dd class="font-mono">{@sidebar_section}</dd>
          </dl>
        </section>
      </main>
    </div>
    """
  end

  @impl true
  def handle_event("sidebar_section", %{"section" => section}, socket)
      when section in ["collections", "history"] do
    {:noreply, assign(socket, :sidebar_section, String.to_existing_atom(section))}
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
