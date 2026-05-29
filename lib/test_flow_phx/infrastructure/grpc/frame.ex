defmodule TestFlowPhx.Infrastructure.Grpc.Frame do
  @moduledoc """
  Framing de mensajes gRPC sobre HTTP/2.

  Un frame gRPC es trivial: 1 byte de flag de compresión (0 = sin comprimir),
  4 bytes big-endian de longitud, y el payload protobuf:

      <<compressed::8, byte_size(proto)::32, proto::binary>>

  Skeleton de Fase N.1 — implementación en Fase N.4.

  ## Regla de acoplamiento

  Parte del cliente gRPC propio. Cero referencias al domain/infra de TestFlow.
  """

  @doc """
  Envuelve bytes protobuf en un frame gRPC sin compresión.

  TODO(N.4): implementar.
  """
  @spec encode(proto_bytes :: binary()) :: binary()
  def encode(_proto_bytes), do: raise("TestFlowPhx.Infrastructure.Grpc.Frame.encode/1 no implementado (Fase N.4)")

  @doc """
  Parsea uno o más frames gRPC concatenados en una lista de payloads protobuf.

  TODO(N.4): implementar.
  """
  @spec decode(bytes :: binary()) :: [binary()]
  def decode(_bytes), do: raise("TestFlowPhx.Infrastructure.Grpc.Frame.decode/1 no implementado (Fase N.4)")
end
