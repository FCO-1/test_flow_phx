defmodule TestFlowPhx.Infrastructure.Storage.GrpcJsonFileRepo do
  @moduledoc """
  Adapter de infrastructure que implementa
  `TestFlowPhx.Domain.Ports.GrpcCollectionRepo` sobre un archivo JSON
  (`data/grpc/state.json` por defecto).

  Espejo de `JsonFileRepo` (REST) pero aislado y acotado: solo colecciones
  gRPC + tabs (sin history ni globals — ver el port). Misma arquitectura:
  estado en memoria como fuente de verdad, escrituras debounced (500 ms),
  flush final en `terminate/2`, broadcast por PubSub en cada mutación.

  Es un GenServer aparte del REST, con su propio topic PubSub
  (`"grpc_storage"`) y su propio archivo, para no interferir con el store REST.

  ## Opciones

    * `:name` — nombre registrado (default: este módulo)
    * `:path` — ruta del JSON (default: `Paths.grpc_state_file/0`)
    * `:pubsub` — servidor PubSub (default: `TestFlowPhx.PubSub`)
    * `:topic` — topic PubSub (default: `"grpc_storage"`)
    * `:flush_after_ms` — ventana de debounce (default: 500)
  """

  use GenServer

  @behaviour TestFlowPhx.Domain.Ports.GrpcCollectionRepo

  alias TestFlowPhx.Domain.Grpc.{Collection, Request}
  alias TestFlowPhx.Infrastructure.Storage.{GrpcSerializer, Paths}

  @default_topic "grpc_storage"
  @default_flush_after_ms 500

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
  def list_tabs, do: GenServer.call(__MODULE__, :list_tabs)

  @impl true
  def active_tab_id, do: GenServer.call(__MODULE__, :active_tab_id)

  @impl true
  def set_tabs(tabs, active_id) when is_list(tabs),
    do: GenServer.call(__MODULE__, {:set_tabs, tabs, active_id})

  @impl true
  def subscribe do
    topic = call_config(:grpc_topic, @default_topic)
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
    path = Keyword.get(opts, :path, Paths.grpc_state_file())
    pubsub = Keyword.get(opts, :pubsub, TestFlowPhx.PubSub)
    topic = Keyword.get(opts, :topic, @default_topic)
    flush_after_ms = Keyword.get(opts, :flush_after_ms, @default_flush_after_ms)

    Process.flag(:trap_exit, true)

    File.mkdir_p!(Path.dirname(path))

    document = load_from_disk(path)

    state = %{
      path: path,
      pubsub: pubsub,
      topic: topic,
      flush_after_ms: flush_after_ms,
      flush_pending?: false,
      collections: document.collections,
      tabs: document.tabs,
      active_tab_id: document.active_tab_id
    }

    {:ok, state}
  end

  # ----- Reads -----

  @impl true
  def handle_call(:list_collections, _from, state),
    do: {:reply, state.collections, state}

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
    Phoenix.PubSub.broadcast(state.pubsub, state.topic, :grpc_storage_changed)
  end

  defp write_to_disk(state) do
    payload =
      GrpcSerializer.dump_document(%{
        collections: state.collections,
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
          {:ok, decoded} -> GrpcSerializer.load_document(decoded)
          {:error, _} -> GrpcSerializer.empty_document()
        end

      {:error, _} ->
        GrpcSerializer.empty_document()
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
