defmodule TestFlowPhx.Infrastructure.Storage.JsonFileRepo do
  @moduledoc """
  Infrastructure adapter implementing `TestFlowPhx.Domain.Ports.RequestRepo`
  on top of a JSON file (`data/state.json` by default).

  Architecture:
    * In-memory state acts as the source of truth during a run.
    * Writes mutate the state synchronously and schedule a debounced
      `:flush` (500 ms) that writes the JSON to disk.
    * `terminate/2` performs one final flush so a graceful shutdown never
      loses recent edits.
    * Every mutation broadcasts `:storage_changed` over `Phoenix.PubSub`
      on the configured topic so subscribers (e.g. LiveView) can refresh.

  ## Options

    * `:name` — registered name (default: this module)
    * `:path` — full path to the JSON file (default: `Paths.state_file/0`)
    * `:pubsub` — PubSub server (default: `TestFlowPhx.PubSub`)
    * `:topic` — PubSub topic (default: `"storage"`)
    * `:flush_after_ms` — debounce window (default: 500)
    * `:history_cap` — max history entries kept (default: 100)
  """

  use GenServer

  @behaviour TestFlowPhx.Domain.Ports.RequestRepo

  alias TestFlowPhx.Domain.{Collection, HistoryEntry, Request}
  alias TestFlowPhx.Infrastructure.Storage.{Paths, Serializer}

  @default_topic "storage"
  @default_flush_after_ms 500
  @default_history_cap 100

  # ----- Behaviour delegations -----

  @impl true
  def list_collections, do: GenServer.call(__MODULE__, :list_collections)

  @impl true
  def upsert_collection(%Collection{} = c),
    do: GenServer.call(__MODULE__, {:upsert_collection, c})

  @impl true
  def delete_collection(id) when is_binary(id),
    do: GenServer.call(__MODULE__, {:delete_collection, id})

  @impl true
  def clear_collections, do: GenServer.call(__MODULE__, :clear_collections)

  @impl true
  def upsert_request_in(collection_id, %Request{} = r) when is_binary(collection_id),
    do: GenServer.call(__MODULE__, {:upsert_request_in, collection_id, r})

  @impl true
  def delete_request_in(collection_id, request_id)
      when is_binary(collection_id) and is_binary(request_id),
      do: GenServer.call(__MODULE__, {:delete_request_in, collection_id, request_id})

  @impl true
  def list_history(limit \\ 50) when is_integer(limit) and limit > 0,
    do: GenServer.call(__MODULE__, {:list_history, limit})

  @impl true
  def append_history(%HistoryEntry{} = h),
    do: GenServer.call(__MODULE__, {:append_history, h})

  @impl true
  def clear_history, do: GenServer.call(__MODULE__, :clear_history)

  @impl true
  def list_tabs, do: GenServer.call(__MODULE__, :list_tabs)

  @impl true
  def active_tab_id, do: GenServer.call(__MODULE__, :active_tab_id)

  @impl true
  def set_tabs(tabs, active_id) when is_list(tabs),
    do: GenServer.call(__MODULE__, {:set_tabs, tabs, active_id})

  @impl true
  def subscribe do
    topic = call_config(:topic, @default_topic)
    pubsub = call_config(:pubsub, TestFlowPhx.PubSub)
    Phoenix.PubSub.subscribe(pubsub, topic)
  end

  # ----- GenServer plumbing -----

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, Paths.state_file())
    pubsub = Keyword.get(opts, :pubsub, TestFlowPhx.PubSub)
    topic = Keyword.get(opts, :topic, @default_topic)
    flush_after_ms = Keyword.get(opts, :flush_after_ms, @default_flush_after_ms)
    history_cap = Keyword.get(opts, :history_cap, @default_history_cap)

    Process.flag(:trap_exit, true)

    File.mkdir_p!(Path.dirname(path))

    document = load_from_disk(path)

    state = %{
      path: path,
      pubsub: pubsub,
      topic: topic,
      flush_after_ms: flush_after_ms,
      history_cap: history_cap,
      flush_pending?: false,
      collections: document.collections,
      history: document.history,
      tabs: document.tabs,
      active_tab_id: document.active_tab_id
    }

    {:ok, state}
  end

  # ----- Reads -----

  @impl true
  def handle_call(:list_collections, _from, state),
    do: {:reply, state.collections, state}

  def handle_call({:list_history, limit}, _from, state),
    do: {:reply, Enum.take(state.history, limit), state}

  def handle_call(:list_tabs, _from, state),
    do: {:reply, state.tabs, state}

  def handle_call(:active_tab_id, _from, state),
    do: {:reply, state.active_tab_id, state}

  # ----- Writes (collections) -----

  def handle_call({:upsert_collection, %Collection{} = c}, _from, state) do
    new_collections = upsert_by_id(state.collections, ensure_id(c))
    state = %{state | collections: new_collections} |> mark_dirty()
    {:reply, :ok, state}
  end

  def handle_call({:delete_collection, id}, _from, state) do
    new_collections = Enum.reject(state.collections, &(&1.id == id))
    state = %{state | collections: new_collections} |> mark_dirty()
    {:reply, :ok, state}
  end

  def handle_call(:clear_collections, _from, state) do
    state = %{state | collections: []} |> mark_dirty()
    {:reply, :ok, state}
  end

  # ----- Writes (requests inside a collection) -----

  def handle_call({:upsert_request_in, collection_id, %Request{} = req}, _from, state) do
    new_collections =
      Enum.map(state.collections, fn
        %Collection{id: ^collection_id} = c ->
          %{c | requests: upsert_by_id(c.requests, ensure_id(req))}

        c ->
          c
      end)

    state = %{state | collections: new_collections} |> mark_dirty()
    {:reply, :ok, state}
  end

  def handle_call({:delete_request_in, collection_id, request_id}, _from, state) do
    new_collections =
      Enum.map(state.collections, fn
        %Collection{id: ^collection_id} = c ->
          %{c | requests: Enum.reject(c.requests, &(&1.id == request_id))}

        c ->
          c
      end)

    state = %{state | collections: new_collections} |> mark_dirty()
    {:reply, :ok, state}
  end

  # ----- Writes (history) -----

  def handle_call({:append_history, %HistoryEntry{} = h}, _from, state) do
    new_history = [ensure_id(h) | state.history] |> Enum.take(state.history_cap)
    state = %{state | history: new_history} |> mark_dirty()
    {:reply, :ok, state}
  end

  def handle_call(:clear_history, _from, state) do
    state = %{state | history: []} |> mark_dirty()
    {:reply, :ok, state}
  end

  # ----- Writes (tabs) -----

  def handle_call({:set_tabs, tabs, active_id}, _from, state) do
    tabs = Enum.map(tabs, &ensure_id/1)
    state = %{state | tabs: tabs, active_tab_id: active_id} |> mark_dirty()
    {:reply, :ok, state}
  end

  # ----- Flush -----

  @impl true
  def handle_info(:flush, state) do
    write_to_disk(state)
    {:noreply, %{state | flush_pending?: false}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.flush_pending?, do: write_to_disk(state)
    :ok
  end

  # ----- Helpers -----

  defp mark_dirty(state) do
    broadcast(state)

    if state.flush_pending? do
      state
    else
      Process.send_after(self(), :flush, state.flush_after_ms)
      %{state | flush_pending?: true}
    end
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(state.pubsub, state.topic, :storage_changed)
  end

  defp write_to_disk(state) do
    payload =
      Serializer.dump_document(%{
        collections: state.collections,
        history: state.history,
        tabs: state.tabs,
        active_tab_id: state.active_tab_id
      })

    json = Jason.encode_to_iodata!(payload, pretty: true)
    tmp = state.path <> ".tmp"
    File.write!(tmp, json)
    File.rename!(tmp, state.path)
  end

  defp load_from_disk(path) do
    case File.read(path) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, decoded} -> Serializer.load_document(decoded)
          {:error, _} -> Serializer.empty_document()
        end

      {:error, :enoent} ->
        Serializer.empty_document()

      {:error, _} ->
        Serializer.empty_document()
    end
  end

  defp upsert_by_id(list, %{id: id} = item) do
    case Enum.find_index(list, &(&1.id == id)) do
      nil -> list ++ [item]
      idx -> List.replace_at(list, idx, item)
    end
  end

  defp ensure_id(%{id: nil} = item), do: %{item | id: Request.new_id()}
  defp ensure_id(%{id: ""} = item), do: %{item | id: Request.new_id()}
  defp ensure_id(item), do: item

  defp call_config(key, default),
    do: Application.get_env(:test_flow_phx, key, default)
end
