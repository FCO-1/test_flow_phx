defmodule TestFlowPhx.Infrastructure.Grpc.WireCodec do
  @moduledoc """
  Encoder/decoder de protobuf **wire format**, descriptor-driven.

  Interpreta descriptores `Google.Protobuf.DescriptorProto` (lo que produce
  protoc + `FileDescriptorSet.decode/1`) para serializar/parsear mensajes sin
  generar structs. Cubre proto3 completo: varint (int32/64, uint32/64,
  sint32/64, bool, enum), fixed32/64 + float/double, length-delimited
  (string, bytes, mensajes anidados), repeated (packed y unpacked) y maps.

  ## Representación interna de un mensaje

  Un mensaje es un **mapa con llaves string = nombre del campo** (el `name` del
  descriptor):

      %{"id" => 7, "name" => "ada", "tags" => ["x", "y"], "meta" => %{"k" => 1}}

  - escalares → número / boolean / binary de Elixir
  - **enum → entero** (su número en el wire; el mapeo nombre↔número es tarea de
    una capa superior con el `EnumDescriptorProto`)
  - mensaje anidado → mapa anidado
  - repeated → lista
  - map → `%{clave => valor}` de Elixir

  ## Presencia explícita

  `encode/3` serializa **todo campo presente** en el mapa (incluido un cero),
  y omite las llaves ausentes. No aplica la omisión proto3 de valores por
  defecto: para un cliente es más predecible mandar lo que el usuario puso, y
  los servidores tratan ausente y cero igual. Esto da round-trip exacto de las
  llaves presentes.

  ## Resolución de tipos anidados

  Para `TYPE_MESSAGE` (incluidos los entries de un map) se necesita el
  descriptor del submensaje. `encode/3` y `decode/3` reciben un `registry`:
  un mapa `%{type_name => Google.Protobuf.DescriptorProto.t()}` donde
  `type_name` es el FQN con punto inicial (`".pkg.Msg"`). Lo construye
  `ProtoLoader` (Fase N.3). Sin tipos anidados, `%{}` basta.

  ## Regla de acoplamiento

  Parte del cliente gRPC propio. Cero referencias al domain/otra infra de
  TestFlow. Entradas/salidas genéricas: descriptores, mapas, bytes.
  """

  import Bitwise

  alias Google.Protobuf.DescriptorProto

  @wire_varint 0
  @wire_i64 1
  @wire_len 2
  @wire_i32 5

  @varint_types ~w(TYPE_INT32 TYPE_INT64 TYPE_UINT32 TYPE_UINT64 TYPE_SINT32 TYPE_SINT64 TYPE_BOOL TYPE_ENUM)a
  @i64_types ~w(TYPE_FIXED64 TYPE_SFIXED64 TYPE_DOUBLE)a
  @i32_types ~w(TYPE_FIXED32 TYPE_SFIXED32 TYPE_FLOAT)a
  @len_types ~w(TYPE_STRING TYPE_BYTES TYPE_MESSAGE)a

  @typedoc "Mapa de FQN (`\".pkg.Msg\"`) a su descriptor, para resolver anidados."
  @type registry :: %{optional(String.t()) => DescriptorProto.t()}

  # ── API pública ───────────────────────────────────────────────────────────

  @doc """
  Serializa un mapa `%{field_name => value}` a bytes protobuf según `desc`.
  """
  @spec encode(DescriptorProto.t(), map(), registry()) :: binary()
  def encode(%DescriptorProto{} = desc, value, registry \\ %{}) when is_map(value) do
    desc.field
    |> Enum.reduce([], fn f, acc ->
      case Map.fetch(value, f.name) do
        {:ok, v} when v != nil -> [acc | encode_field(f, v, registry)]
        _ -> acc
      end
    end)
    |> IO.iodata_to_binary()
  end

  @doc """
  Parsea bytes protobuf a un mapa `%{field_name => value}` según `desc`.
  Campos no declarados en `desc` se descartan (forward-compat).
  """
  @spec decode(DescriptorProto.t(), binary(), registry()) :: map()
  def decode(%DescriptorProto{} = desc, bytes, registry \\ %{}) when is_binary(bytes) do
    index = Map.new(desc.field, &{&1.number, &1})

    bytes
    |> do_decode(index, registry, %{})
    |> reverse_repeated()
  end

  # ── Helpers de bajo nivel (varint / zigzag / tag) ─────────────────────────

  @doc "Codifica un entero no negativo como varint base-128."
  @spec encode_varint(non_neg_integer()) :: binary()
  def encode_varint(n) when is_integer(n) and n >= 0, do: do_encode_varint(n)

  defp do_encode_varint(n) when n < 0x80, do: <<n>>
  defp do_encode_varint(n), do: <<bor(band(n, 0x7F), 0x80)>> <> do_encode_varint(bsr(n, 7))

  @doc "Decodifica un varint del inicio del binario. Devuelve `{valor, resto}`."
  @spec decode_varint(binary()) :: {non_neg_integer(), binary()}
  def decode_varint(bin), do: decode_varint(bin, 0, 0)

  defp decode_varint(<<1::1, b::7, rest::binary>>, shift, acc),
    do: decode_varint(rest, shift + 7, bor(acc, bsl(b, shift)))

  defp decode_varint(<<0::1, b::7, rest::binary>>, shift, acc),
    do: {bor(acc, bsl(b, shift)), rest}

  @doc "Zigzag-codifica un entero con signo de `bits` (32 o 64) a no negativo."
  @spec zigzag(integer(), 32 | 64) :: non_neg_integer()
  def zigzag(n, bits), do: bxor(bsl(n, 1), bsr(n, bits - 1))

  @doc "Inversa de `zigzag/2`."
  @spec unzigzag(non_neg_integer()) :: integer()
  def unzigzag(u), do: bxor(bsr(u, 1), -band(u, 1))

  @doc "Codifica el tag `(field_number << 3) | wire_type`."
  @spec encode_tag(pos_integer(), 0..5) :: binary()
  def encode_tag(field_number, wire_type), do: encode_varint(bor(bsl(field_number, 3), wire_type))

  @doc "Decodifica un tag. Devuelve `{field_number, wire_type, resto}`."
  @spec decode_tag(binary()) :: {pos_integer(), 0..5, binary()}
  def decode_tag(bin) do
    {tag, rest} = decode_varint(bin)
    {bsr(tag, 3), band(tag, 7), rest}
  end

  # ── Encode ────────────────────────────────────────────────────────────────

  defp encode_field(f, v, registry) do
    cond do
      repeated?(f) and map_field?(f, registry) -> encode_map_field(f, v, registry)
      repeated?(f) -> encode_repeated(f, v, registry)
      true -> encode_singular(f, v, registry)
    end
  end

  defp encode_singular(f, v, registry),
    do: [encode_tag(f.number, wire_type(f.type)), encode_value(f, v, registry)]

  # Payload de un campo (con prefijo de longitud para los LEN).
  defp encode_value(%{type: :TYPE_MESSAGE} = f, v, registry) do
    blob = encode(resolve!(f.type_name, registry), v, registry)
    [encode_varint(byte_size(blob)), blob]
  end

  defp encode_value(%{type: t}, v, _registry) when t in [:TYPE_STRING, :TYPE_BYTES],
    do: [encode_varint(byte_size(v)), v]

  defp encode_value(%{type: t}, v, _registry), do: encode_scalar(t, v)

  # Escalar sin tag ni prefijo (para singular numérico y para packed).
  defp encode_scalar(t, v) when t in @varint_types, do: encode_varint(to_varint(t, v))
  defp encode_scalar(:TYPE_FIXED32, v), do: <<v::little-32>>
  defp encode_scalar(:TYPE_SFIXED32, v), do: <<v::little-signed-32>>
  defp encode_scalar(:TYPE_FLOAT, v), do: <<v::little-float-32>>
  defp encode_scalar(:TYPE_FIXED64, v), do: <<v::little-64>>
  defp encode_scalar(:TYPE_SFIXED64, v), do: <<v::little-signed-64>>
  defp encode_scalar(:TYPE_DOUBLE, v), do: <<v::little-float-64>>

  defp to_varint(:TYPE_BOOL, true), do: 1
  defp to_varint(:TYPE_BOOL, false), do: 0
  defp to_varint(:TYPE_SINT32, v), do: zigzag(v, 32)
  defp to_varint(:TYPE_SINT64, v), do: zigzag(v, 64)
  defp to_varint(t, v) when t in [:TYPE_UINT32, :TYPE_UINT64], do: v
  # int32/int64/enum: negativos se sign-extienden a 64 bits sin signo.
  defp to_varint(_t, v) when v < 0, do: v + bsl(1, 64)
  defp to_varint(_t, v), do: v

  # repeated: escalares numéricos → packed (un tag + blob); string/bytes/msg → tag por elemento.
  defp encode_repeated(f, list, registry) do
    if packable?(f.type) do
      blob = list |> Enum.reduce([], &[&2, encode_scalar(f.type, &1)]) |> IO.iodata_to_binary()
      [encode_tag(f.number, @wire_len), encode_varint(byte_size(blob)), blob]
    else
      Enum.map(list, &encode_singular(f, &1, registry))
    end
  end

  defp encode_map_field(f, map, registry) do
    entry = resolve!(f.type_name, registry)

    Enum.map(map, fn {k, v} ->
      blob = encode(entry, %{"key" => k, "value" => v}, registry)
      [encode_tag(f.number, @wire_len), encode_varint(byte_size(blob)), blob]
    end)
  end

  # ── Decode ──────────────────────────────────────────────────────────────────

  defp do_decode(<<>>, _index, _registry, acc), do: acc

  defp do_decode(bin, index, registry, acc) do
    {field_number, wire, rest} = decode_tag(bin)

    {acc, rest} =
      case Map.get(index, field_number) do
        nil -> {acc, skip(wire, rest)}
        f -> decode_field(f, wire, rest, registry, acc)
      end

    do_decode(rest, index, registry, acc)
  end

  # LEN sobre un campo escalar repetido = bloque packed.
  defp decode_field(%{type: t} = f, @wire_len, bin, _registry, acc) when t not in @len_types do
    {blob, rest} = read_len(bin)
    values = decode_packed(t, blob)
    {Enum.reduce(values, acc, &append(&2, f, &1)), rest}
  end

  defp decode_field(%{type: :TYPE_MESSAGE} = f, @wire_len, bin, registry, acc) do
    {blob, rest} = read_len(bin)

    if map_field?(f, registry) do
      entry = resolve!(f.type_name, registry)
      {k, v} = decode_map_entry(entry, blob, registry)
      {put_map(acc, f, k, v), rest}
    else
      decoded = decode(resolve!(f.type_name, registry), blob, registry)
      {add(acc, f, decoded), rest}
    end
  end

  defp decode_field(%{type: t} = f, @wire_len, bin, _registry, acc)
       when t in [:TYPE_STRING, :TYPE_BYTES] do
    {blob, rest} = read_len(bin)
    {add(acc, f, blob), rest}
  end

  # Escalar sin packing (wire 0/1/5).
  defp decode_field(f, _wire, bin, _registry, acc) do
    {value, rest} = decode_scalar(f.type, bin)
    {add(acc, f, value), rest}
  end

  defp decode_map_entry(entry, blob, registry) do
    decoded = decode(entry, blob, registry)
    key_f = Enum.find(entry.field, &(&1.number == 1))
    val_f = Enum.find(entry.field, &(&1.number == 2))
    {Map.get(decoded, "key", default_for(key_f)), Map.get(decoded, "value", default_for(val_f))}
  end

  defp decode_packed(_type, <<>>), do: []

  defp decode_packed(type, bin) do
    {v, rest} = decode_scalar(type, bin)
    [v | decode_packed(type, rest)]
  end

  defp decode_scalar(t, bin) when t in @varint_types do
    {u, rest} = decode_varint(bin)
    {from_varint(t, u), rest}
  end

  defp decode_scalar(t, bin) when t in @i64_types do
    <<raw::binary-8, rest::binary>> = bin
    {from_i64(t, raw), rest}
  end

  defp decode_scalar(t, bin) when t in @i32_types do
    <<raw::binary-4, rest::binary>> = bin
    {from_i32(t, raw), rest}
  end

  defp from_varint(:TYPE_BOOL, u), do: u != 0
  defp from_varint(t, u) when t in [:TYPE_SINT32, :TYPE_SINT64], do: unzigzag(u)
  defp from_varint(t, u) when t in [:TYPE_UINT32, :TYPE_UINT64], do: u
  defp from_varint(_t, u), do: to_signed64(u)

  defp from_i32(:TYPE_FIXED32, <<v::little-32>>), do: v
  defp from_i32(:TYPE_SFIXED32, <<v::little-signed-32>>), do: v
  defp from_i32(:TYPE_FLOAT, <<v::little-float-32>>), do: v

  defp from_i64(:TYPE_FIXED64, <<v::little-64>>), do: v
  defp from_i64(:TYPE_SFIXED64, <<v::little-signed-64>>), do: v
  defp from_i64(:TYPE_DOUBLE, <<v::little-float-64>>), do: v

  defp to_signed64(u) when u >= bsl(1, 63), do: u - bsl(1, 64)
  defp to_signed64(u), do: u

  # ── skip de campos desconocidos ─────────────────────────────────────────────

  defp skip(@wire_varint, bin), do: elem(decode_varint(bin), 1)
  defp skip(@wire_i64, <<_::binary-8, rest::binary>>), do: rest
  defp skip(@wire_i32, <<_::binary-4, rest::binary>>), do: rest

  defp skip(@wire_len, bin) do
    {_blob, rest} = read_len(bin)
    rest
  end

  # ── Helpers comunes ──────────────────────────────────────────────────────────

  defp read_len(bin) do
    {len, rest} = decode_varint(bin)
    <<blob::binary-size(len), rest2::binary>> = rest
    {blob, rest2}
  end

  defp repeated?(f), do: f.label == :LABEL_REPEATED

  defp packable?(type), do: type not in @len_types

  defp map_field?(%{type: :TYPE_MESSAGE} = f, registry) do
    case Map.get(registry, f.type_name) do
      %DescriptorProto{options: %{map_entry: true}} -> true
      _ -> false
    end
  end

  defp map_field?(_f, _registry), do: false

  defp resolve!(type_name, registry) do
    case Map.get(registry, type_name) do
      %DescriptorProto{} = d -> d
      _ -> raise ArgumentError, "tipo de mensaje no encontrado en el registry: #{inspect(type_name)}"
    end
  end

  defp wire_type(t) when t in @varint_types, do: @wire_varint
  defp wire_type(t) when t in @i64_types, do: @wire_i64
  defp wire_type(t) when t in @i32_types, do: @wire_i32
  defp wire_type(t) when t in @len_types, do: @wire_len

  defp default_for(%{type: t}) when t in [:TYPE_STRING, :TYPE_BYTES], do: ""
  defp default_for(%{type: :TYPE_BOOL}), do: false
  defp default_for(%{type: :TYPE_MESSAGE}), do: nil
  defp default_for(%{type: t}) when t in [:TYPE_FLOAT, :TYPE_DOUBLE], do: 0.0
  defp default_for(_), do: 0

  # acc: %{field_name => value | [value, ...] (repeated, en reversa) | %{} (map)}
  defp add(acc, f, value) do
    if repeated?(f), do: append(acc, f, value), else: Map.put(acc, f.name, value)
  end

  defp append(acc, f, value), do: Map.update(acc, f.name, [value], &[value | &1])

  defp put_map(acc, f, k, v), do: Map.update(acc, f.name, %{k => v}, &Map.put(&1, k, v))

  defp reverse_repeated(acc) do
    Map.new(acc, fn
      {k, v} when is_list(v) -> {k, Enum.reverse(v)}
      pair -> pair
    end)
  end
end
