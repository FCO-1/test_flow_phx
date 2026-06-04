defmodule TestFlowPhx.Infrastructure.Grpc.JsonCodec do
  @moduledoc """
  Puente entre el **JSON del usuario** y la representación de mapa que consume
  `WireCodec` (`%{field_name => value}`, ver su moduledoc).

  El usuario escribe el mensaje como JSON; tras `Jason.decode/1` queda un valor
  con llaves string y escalares nativos. Ese valor casi coincide con el mapa de
  WireCodec, pero hay desajustes que este módulo resuelve, dirigido por el
  descriptor (proto3 JSON mapping, versión acotada):

    * **bytes** ↔ base64 (`to_message` decodifica, `from_message` codifica).
    * **enum** ↔ acepta número o nombre; emite el nombre si hay `EnumDescriptor`.
    * **int64/uint64/...64** acepta número o string numérica (convención JSON).
    * **float/double** coacciona enteros a float (WireCodec exige float real).
    * **mensajes anidados / repeated / maps** recurren con el `registry`.

  `registry` y `enums` son los que produce `ProtoLoader` (`messages_by_name`,
  `enums_by_name`).

  ## Regla de acoplamiento

  Parte del motor gRPC. Entradas/salidas genéricas (descriptores, mapas, JSON);
  cero referencias al domain de TestFlow.
  """

  alias Google.Protobuf.{DescriptorProto, EnumDescriptorProto}

  @int64_types ~w(TYPE_INT64 TYPE_UINT64 TYPE_SINT64 TYPE_FIXED64 TYPE_SFIXED64)a
  @int32_types ~w(TYPE_INT32 TYPE_UINT32 TYPE_SINT32 TYPE_FIXED32 TYPE_SFIXED32)a
  @float_types ~w(TYPE_FLOAT TYPE_DOUBLE)a

  @type registry :: %{optional(String.t()) => DescriptorProto.t()}
  @type enums :: %{optional(String.t()) => EnumDescriptorProto.t()}

  # ── JSON → mapa WireCodec ───────────────────────────────────────────────────

  @doc """
  Convierte un valor JSON-decodificado (mapa string-keyed) al mapa que espera
  `WireCodec.encode/3`, según `desc`. Devuelve `{:ok, map}` o `{:error, msg}`.
  """
  @spec to_message(DescriptorProto.t(), map(), registry(), enums()) ::
          {:ok, map()} | {:error, String.t()}
  def to_message(%DescriptorProto{} = desc, json, registry, enums \\ %{}) when is_map(json) do
    {:ok, build_message(desc, json, registry, enums)}
  rescue
    e in [ArgumentError, FunctionClauseError, KeyError] ->
      {:error, Exception.message(e)}
  end

  defp build_message(desc, json, registry, enums) do
    Enum.reduce(desc.field, %{}, fn f, acc ->
      case Map.fetch(json, f.name) do
        {:ok, nil} -> acc
        {:ok, v} -> Map.put(acc, f.name, to_field(f, v, registry, enums))
        :error -> acc
      end
    end)
  end

  defp to_field(f, v, registry, enums) do
    cond do
      map_field?(f, registry) -> to_map_field(f, v, registry, enums)
      repeated?(f) -> Enum.map(List.wrap(v), &to_value(f, &1, registry, enums))
      true -> to_value(f, v, registry, enums)
    end
  end

  defp to_map_field(f, obj, registry, enums) when is_map(obj) do
    entry = resolve!(f.type_name, registry)
    key_f = field_no(entry, 1)
    val_f = field_no(entry, 2)

    Map.new(obj, fn {k, v} ->
      {to_value(key_f, k, registry, enums), to_value(val_f, v, registry, enums)}
    end)
  end

  defp to_value(%{type: :TYPE_MESSAGE} = f, v, registry, enums) when is_map(v),
    do: build_message(resolve!(f.type_name, registry), v, registry, enums)

  defp to_value(%{type: :TYPE_ENUM} = f, v, _registry, enums), do: enum_to_number(f, v, enums)
  defp to_value(%{type: :TYPE_BYTES}, v, _registry, _enums) when is_binary(v), do: Base.decode64!(v)
  defp to_value(%{type: t}, v, _r, _e) when t in @int64_types and is_binary(v), do: String.to_integer(v)
  defp to_value(%{type: t}, v, _r, _e) when t in @float_types and is_integer(v), do: v * 1.0
  defp to_value(%{type: t}, v, _r, _e) when t in @int32_types and is_binary(v), do: String.to_integer(v)
  defp to_value(_f, v, _registry, _enums), do: v

  defp enum_to_number(_f, v, _enums) when is_integer(v), do: v

  defp enum_to_number(f, v, enums) when is_binary(v) do
    case Map.get(enums, f.type_name) do
      %EnumDescriptorProto{value: values} ->
        case Enum.find(values, &(&1.name == v)) do
          %{number: n} -> n
          nil -> raise ArgumentError, "valor de enum desconocido: #{inspect(v)} en #{f.type_name}"
        end

      _ ->
        raise ArgumentError, "enum #{f.type_name} no está en el registry; usá su número"
    end
  end

  # ── mapa WireCodec → JSON ───────────────────────────────────────────────────

  @doc """
  Convierte el mapa que devuelve `WireCodec.decode/3` a un valor JSON-amigable
  (bytes→base64, enum→nombre si se conoce, anidados/repeated/maps recurridos).
  """
  @spec from_message(DescriptorProto.t(), map(), registry(), enums()) :: map()
  def from_message(%DescriptorProto{} = desc, map, registry, enums \\ %{}) when is_map(map) do
    index = Map.new(desc.field, &{&1.name, &1})

    Map.new(map, fn {name, v} ->
      {name, from_field(Map.fetch!(index, name), v, registry, enums)}
    end)
  end

  defp from_field(f, v, registry, enums) do
    cond do
      map_field?(f, registry) -> from_map_field(f, v, registry, enums)
      repeated?(f) -> Enum.map(List.wrap(v), &from_value(f, &1, registry, enums))
      true -> from_value(f, v, registry, enums)
    end
  end

  defp from_map_field(f, map, registry, enums) do
    entry = resolve!(f.type_name, registry)
    val_f = field_no(entry, 2)
    Map.new(map, fn {k, v} -> {k, from_value(val_f, v, registry, enums)} end)
  end

  defp from_value(%{type: :TYPE_MESSAGE} = f, v, registry, enums) when is_map(v),
    do: from_message(resolve!(f.type_name, registry), v, registry, enums)

  defp from_value(%{type: :TYPE_ENUM} = f, v, _registry, enums), do: enum_to_name(f, v, enums)
  defp from_value(%{type: :TYPE_BYTES}, v, _registry, _enums) when is_binary(v), do: Base.encode64(v)
  defp from_value(_f, v, _registry, _enums), do: v

  defp enum_to_name(f, n, enums) when is_integer(n) do
    case Map.get(enums, f.type_name) do
      %EnumDescriptorProto{value: values} ->
        case Enum.find(values, &(&1.number == n)) do
          %{name: name} -> name
          nil -> n
        end

      _ ->
        n
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp repeated?(f), do: f.label == :LABEL_REPEATED

  defp map_field?(%{type: :TYPE_MESSAGE} = f, registry) do
    match?(%DescriptorProto{options: %{map_entry: true}}, Map.get(registry, f.type_name))
  end

  defp map_field?(_f, _registry), do: false

  defp field_no(entry, n), do: Enum.find(entry.field, &(&1.number == n))

  defp resolve!(type_name, registry) do
    case Map.get(registry, type_name) do
      %DescriptorProto{} = d -> d
      _ -> raise ArgumentError, "tipo de mensaje no encontrado en el registry: #{inspect(type_name)}"
    end
  end
end
