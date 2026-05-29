defmodule TestFlowPhx.Infrastructure.Grpc.Frame do
  @moduledoc """
  Framing de mensajes gRPC sobre HTTP/2.

  Un frame gRPC es trivial: 1 byte de flag de compresión (0 = sin comprimir),
  4 bytes big-endian de longitud, y el payload protobuf:

      <<compressed::8, byte_size(proto)::32, proto::binary>>

  ## Regla de acoplamiento

  Parte del cliente gRPC propio. Cero referencias al domain/infra de TestFlow.
  """

  @doc """
  Envuelve bytes protobuf en un frame gRPC sin compresión.
  """
  @spec encode(binary()) :: binary()
  def encode(proto_bytes) when is_binary(proto_bytes),
    do: <<0::8, byte_size(proto_bytes)::unsigned-big-32, proto_bytes::binary>>

  @doc """
  Extrae los frames **completos** de `buffer`, devolviendo
  `{payloads, resto}` donde `resto` son los bytes de un frame parcial todavía
  sin completar (relevante en streaming: un mensaje puede partirse entre DATA
  frames de HTTP/2). Cada payload es el protobuf desenmarcado.

  Frames comprimidos (flag != 0) no están soportados en v1: levanta.
  """
  @spec decode(binary()) :: {[binary()], binary()}
  def decode(buffer) when is_binary(buffer), do: decode(buffer, [])

  defp decode(<<0::8, len::unsigned-big-32, payload::binary-size(len), rest::binary>>, acc),
    do: decode(rest, [payload | acc])

  defp decode(<<flag::8, _::binary>>, _acc) when flag != 0,
    do: raise(ArgumentError, "frame gRPC comprimido no soportado (flag=#{flag})")

  # No alcanza para un frame completo (header de 5 bytes o payload incompleto):
  # se devuelve como resto.
  defp decode(rest, acc), do: {Enum.reverse(acc), rest}
end
