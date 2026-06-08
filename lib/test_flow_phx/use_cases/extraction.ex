defmodule TestFlowPhx.UseCases.Extraction do
  @moduledoc """
  Extrae valores de un cuerpo de respuesta ya **decodificado** (map/list
  anidados, p.ej. el `body_decoded` de un Response gRPC o el JSON de un Response
  REST) usando un **dot-path** simple.

  El path es una secuencia de claves separadas por `.`; un segmento numérico
  indexa una lista (base 0). Ejemplos:

      "cuerpo.token"            → data["cuerpo"]["token"]
      "mensajes.0.id.valor"     → data["mensajes"] |> Enum.at(0) ...

  Genérico y sin acoplar a un protocolo, para que REST pueda reusarlo. Es la
  base del "encadenado de respuestas": el valor extraído se guarda en una
  variable (vía `Globals.put/2`) y el siguiente request lo usa con `{{var}}`.
  """

  @doc """
  Devuelve `{:ok, value}` con el valor en `path`, o `:error` si el path no
  existe. `value` conserva su tipo original (string/number/bool/map/list).
  """
  @spec get(any(), String.t()) :: {:ok, any()} | :error
  def get(data, path) when is_binary(path) do
    case String.split(path, ".", trim: true) do
      [] -> :error
      keys -> traverse(data, keys)
    end
  end

  def get(_data, _path), do: :error

  defp traverse(value, []), do: {:ok, value}

  defp traverse(data, [key | rest]) when is_map(data) do
    case Map.fetch(data, key) do
      {:ok, value} -> traverse(value, rest)
      :error -> :error
    end
  end

  defp traverse(list, [key | rest]) when is_list(list) do
    case Integer.parse(key) do
      {idx, ""} ->
        case Enum.fetch(list, idx) do
          {:ok, value} -> traverse(value, rest)
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp traverse(_data, _keys), do: :error

  @doc """
  Convierte un valor extraído a string, listo para guardar como variable.
  Strings tal cual; números/bool a texto; map/list a JSON; `nil` a "".
  """
  @spec to_value(any()) :: String.t()
  def to_value(value) when is_binary(value), do: value
  def to_value(value) when is_number(value), do: to_string(value)
  def to_value(value) when is_boolean(value), do: to_string(value)
  def to_value(nil), do: ""
  def to_value(value), do: Jason.encode!(value)
end
