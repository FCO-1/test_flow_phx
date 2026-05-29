defmodule TestFlowPhx.Infrastructure.Grpc.WireCodec do
  @moduledoc """
  Encoder/decoder de protobuf **wire format**, descriptor-driven.

  Skeleton de Fase N.1 — sin lógica todavía. La implementación llega en
  Fase N.2 (varint, zigzag, length-delimited, fixed32/64, packed repeated,
  nested messages, enums, oneof, maps) con tests de round-trip por tipo.

  ## Regla de acoplamiento

  Este módulo es parte del **cliente gRPC propio**, diseñado como librería
  separable. NO debe referenciar el domain ni la infraestructura de TestFlow
  (`Request`, `Collection`, `JsonFileRepo`, `Application.get_env/2`, …). Sus
  entradas y salidas son tipos genéricos: descriptores protobuf, mapas, bytes.

  ## Representación interna

  Un mensaje se representa como un mapa `%{field_name => value}` (decisión a
  fijar en N.2), serializado/parseado contra el `Google.Protobuf.DescriptorProto`
  correspondiente — no se generan structs.
  """

  @doc """
  Serializa `value` a bytes protobuf según el descriptor del mensaje.

  TODO(N.2): implementar.
  """
  @spec encode(descriptor :: term(), value :: map()) :: binary()
  def encode(_descriptor, _value), do: raise("TestFlowPhx.Infrastructure.Grpc.WireCodec.encode/2 no implementado (Fase N.2)")

  @doc """
  Parsea `bytes` protobuf a un mapa según el descriptor del mensaje.

  TODO(N.2): implementar.
  """
  @spec decode(descriptor :: term(), bytes :: binary()) :: map()
  def decode(_descriptor, _bytes), do: raise("TestFlowPhx.Infrastructure.Grpc.WireCodec.decode/2 no implementado (Fase N.2)")
end
