defmodule TestFlowPhx.Infrastructure.Grpc.Http2Client do
  @moduledoc """
  Wrapper HTTP/2 sobre `Mint.HTTP2` — un proceso = una conexión.

  Provee connect / request / recv para el cliente gRPC, acumulando frames
  hasta `:done` o trailers. El streaming (Fase N.6) emite cada frame al
  consumidor.

  Skeleton de Fase N.1 — implementación en Fase N.4 (probablemente como
  GenServer dedicado para streams largos; fallback a `:gun` si Mint no se
  presta, ver riesgo #3 del plan).

  ## Regla de acoplamiento

  Parte del cliente gRPC propio. Cero referencias al domain/infra de TestFlow.
  """

  @doc """
  Abre una conexión HTTP/2 a `host:port`.

  TODO(N.4): implementar.
  """
  @spec connect(host :: String.t(), port :: :inet.port_number(), opts :: keyword()) ::
          {:ok, term()} | {:error, term()}
  def connect(_host, _port, _opts \\ []),
    do: raise("TestFlowPhx.Infrastructure.Grpc.Http2Client.connect/3 no implementado (Fase N.4)")

  @doc """
  Emite un request HTTP/2 (method, path, headers, body) sobre la conexión.

  TODO(N.4): implementar.
  """
  @spec request(conn :: term(), method :: String.t(), path :: String.t(), headers :: list(), body :: binary()) ::
          {:ok, term()} | {:error, term()}
  def request(_conn, _method, _path, _headers, _body),
    do: raise("TestFlowPhx.Infrastructure.Grpc.Http2Client.request/5 no implementado (Fase N.4)")

  @doc """
  Acumula respuestas del stream hasta `:done` o trailers.

  TODO(N.4): implementar.
  """
  @spec recv(conn :: term(), timeout :: timeout()) :: {:ok, term()} | {:error, term()}
  def recv(_conn, _timeout),
    do: raise("TestFlowPhx.Infrastructure.Grpc.Http2Client.recv/2 no implementado (Fase N.4)")
end
