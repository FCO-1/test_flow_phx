defmodule TestFlowPhx.UseCases.CollectionImport do
  @moduledoc """
  Parsea un sobre de export de TestFlow (ver `CollectionExport`) y lo
  persiste como colecciones nuevas — nunca sobrescribe existentes, así
  que importar el mismo archivo dos veces produce dos copias. Se asignan
  IDs frescos tanto a las colecciones como a sus requests.
  """

  alias TestFlowPhx.Domain.{Collection, Rest.Request}
  alias TestFlowPhx.Infrastructure.Storage.Serializer
  alias TestFlowPhx.UseCases.Collections

  @format "testflow-collection"
  @max_version 2

  @type error ::
          :invalid_json
          | :unknown_format
          | :unsupported_version
          | :malformed
          | {:malformed, term()}

  @doc """
  Parsea el string JSON del sobre en una lista de nuevas `%Collection{}`.

  NO persiste — ver `import_all/1`. Útil cuando se quiere validar primero
  o hacer un preview antes de confirmar.
  """
  @spec parse(String.t()) :: {:ok, [Collection.t()]} | {:error, error()}
  def parse(json) when is_binary(json) do
    with {:ok, decoded} <- decode(json),
         :ok <- check_envelope(decoded),
         {:ok, list} <- collections_list(decoded) do
      {:ok, Enum.map(list, &load_collection_with_fresh_ids/1)}
    end
  end

  @doc """
  Parse + persiste. Devuelve la cantidad de colecciones importadas si
  tiene éxito.
  """
  @spec import_all(String.t()) :: {:ok, non_neg_integer()} | {:error, error()}
  def import_all(json) when is_binary(json) do
    case parse(json) do
      {:ok, collections} ->
        Enum.each(collections, &Collections.upsert_raw/1)
        {:ok, length(collections)}

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Explicación legible para humanos de un error de parsing.
  """
  @spec format_error(error()) :: String.t()
  def format_error(:invalid_json), do: "El archivo no es JSON válido."
  def format_error(:unknown_format), do: "Formato no reconocido (falta `format: testflow-collection`)."
  def format_error(:unsupported_version), do: "Versión del archivo no soportada."
  def format_error(:malformed), do: "El archivo no tiene la estructura esperada."
  def format_error({:malformed, why}), do: "Estructura inválida: #{inspect(why)}."
  def format_error(other), do: "Error: #{inspect(other)}."

  # ----- Internals -----

  defp decode(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, map}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp check_envelope(%{"format" => @format, "version" => v}) when is_integer(v) do
    if v <= @max_version, do: :ok, else: {:error, :unsupported_version}
  end

  defp check_envelope(%{"format" => _}), do: {:error, :unknown_format}
  defp check_envelope(_), do: {:error, :unknown_format}

  defp collections_list(%{"collections" => list}) when is_list(list), do: {:ok, list}
  defp collections_list(_), do: {:error, :malformed}

  defp load_collection_with_fresh_ids(map) when is_map(map) do
    collection_id = Request.new_id()

    %Collection{
      id: collection_id,
      name: Map.get(map, "name", "Imported"),
      requests:
        map
        |> Map.get("requests", [])
        |> Enum.map(&load_request_with_fresh_id(&1, collection_id)),
      variables: Serializer.load_variables(Map.get(map, "variables"))
    }
  end

  defp load_request_with_fresh_id(map, collection_id) when is_map(map) do
    req = Serializer.load_request(map)
    %{req | id: Request.new_id(), collection_id: collection_id}
  end
end
