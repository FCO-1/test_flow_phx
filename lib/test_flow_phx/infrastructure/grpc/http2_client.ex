defmodule TestFlowPhx.Infrastructure.Grpc.Http2Client do
  @moduledoc """
  Wrapper HTTP/2 sobre `Mint.HTTP2` — un proceso (GenServer) = una conexión.

  Mint es process-less y de bajo nivel: el proceso dueño recibe los mensajes
  del socket y los pasa a `Mint.HTTP2.stream/2`. Este GenServer encapsula eso:
  abre la conexión, emite el request y acumula las respuestas (status, headers,
  data, **trailers**) hasta `:done`, respondiendo entonces al `call` pendiente.

  v1: transporte **cleartext** (`:http`, h2c prior-knowledge) y modelo unary
  (`request/5` colecta todo el response). El consumo por-frame para server
  streaming se agrega en Fase N.6.

  Este módulo es **transport-genérico**: manda los headers que se le den tal
  cual. Los headers propios de gRPC (`content-type: application/grpc+proto`,
  `te: trailers`) los pone el cliente gRPC (`Client`, Fase N.5).

  ## Regla de acoplamiento

  Parte del cliente gRPC propio. Cero referencias al domain/infra de TestFlow.
  """

  use GenServer

  @type response :: %{
          status: non_neg_integer() | nil,
          headers: [{String.t(), String.t()}],
          trailers: [{String.t(), String.t()}],
          body: binary()
        }

  # ── API pública ─────────────────────────────────────────────────────────────

  @doc "Abre una conexión HTTP/2 (cleartext) a `host:port`. Devuelve el pid del canal."
  @spec connect(String.t(), :inet.port_number(), keyword()) :: {:ok, pid()} | {:error, term()}
  def connect(host, port, opts \\ []) do
    # Conectar en el proceso llamador para devolver el error de connect limpio
    # (sin que un {:stop, reason} en init crashee al caller), y luego transferir
    # la propiedad del socket al GenServer — patrón canónico de Mint.
    with {:ok, conn} <- Mint.HTTP2.connect(:http, host, port, opts),
         {:ok, pid} <- GenServer.start_link(__MODULE__, conn),
         {:ok, conn} <- Mint.HTTP2.controlling_process(conn, pid) do
      GenServer.cast(pid, {:set_conn, conn})
      {:ok, pid}
    end
  end

  @doc """
  Emite un request unary (`POST path`, headers, body ya enmarcado) y colecta el
  response completo. `opts`: `timeout` (default 30s).
  """
  @spec request(pid(), String.t(), [{String.t(), String.t()}], binary(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def request(pid, path, headers, body, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(pid, {:request, path, headers, body}, timeout + 1_000)
  end

  @doc "Cierra el canal."
  @spec close(pid()) :: :ok
  def close(pid), do: GenServer.stop(pid)

  # ── Colector puro (testeable sin red) ───────────────────────────────────────

  @doc false
  def init_collector,
    do: %{status: nil, headers: nil, trailers: [], data: [], done?: false, error: nil}

  @doc false
  # El PRIMER bloque de headers es el inicial; los siguientes son trailers.
  def collect(acc, {:status, _ref, status}), do: %{acc | status: status}
  def collect(%{headers: nil} = acc, {:headers, _ref, hs}), do: %{acc | headers: hs}
  def collect(acc, {:headers, _ref, hs}), do: %{acc | trailers: acc.trailers ++ hs}
  def collect(acc, {:data, _ref, data}), do: %{acc | data: [acc.data, data]}
  def collect(acc, {:done, _ref}), do: %{acc | done?: true}
  def collect(acc, {:error, _ref, reason}), do: %{acc | error: reason, done?: true}

  @doc false
  def finalize(%{error: reason}) when reason != nil, do: {:error, reason}

  def finalize(acc) do
    {:ok,
     %{
       status: acc.status,
       headers: acc.headers || [],
       trailers: acc.trailers,
       body: IO.iodata_to_binary(acc.data)
     }}
  end

  # ── GenServer ────────────────────────────────────────────────────────────────

  @impl true
  def init(conn), do: {:ok, %{conn: conn, requests: %{}}}

  @impl true
  def handle_cast({:set_conn, conn}, state), do: {:noreply, %{state | conn: conn}}

  @impl true
  def handle_call({:request, path, headers, body}, from, state) do
    case Mint.HTTP2.request(state.conn, "POST", path, headers, body) do
      {:ok, conn, ref} ->
        requests = Map.put(state.requests, ref, %{from: from, collector: init_collector()})
        {:noreply, %{state | conn: conn, requests: requests}}

      {:error, conn, reason} ->
        {:reply, {:error, reason}, %{state | conn: conn}}
    end
  end

  @impl true
  def handle_info(message, state) do
    case Mint.HTTP2.stream(state.conn, message) do
      :unknown -> {:noreply, state}
      {:ok, conn, responses} -> {:noreply, process(responses, %{state | conn: conn})}
      {:error, conn, _reason, responses} -> {:noreply, process(responses, %{state | conn: conn})}
    end
  end

  @impl true
  def terminate(_reason, %{conn: conn}), do: Mint.HTTP2.close(conn)

  defp process(responses, state) do
    Enum.reduce(responses, state, fn response, state ->
      ref = elem(response, 1)

      case Map.get(state.requests, ref) do
        nil ->
          state

        req ->
          collector = collect(req.collector, response)

          if collector.done? do
            GenServer.reply(req.from, finalize(collector))
            %{state | requests: Map.delete(state.requests, ref)}
          else
            put_in(state.requests[ref], %{req | collector: collector})
          end
      end
    end)
  end
end
