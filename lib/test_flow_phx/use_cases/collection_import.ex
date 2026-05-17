defmodule TestFlowPhx.UseCases.CollectionImport do
  @moduledoc """
  Parses a TestFlow export envelope (see `CollectionExport`) and persists
  it as new collections — never overwrites existing ones, so importing
  the same file twice produces two copies. Fresh IDs are assigned to both
  collections and their requests.
  """

  alias TestFlowPhx.Domain.{Collection, Request}
  alias TestFlowPhx.Infrastructure.Storage.Serializer
  alias TestFlowPhx.UseCases.Collections

  @format "testflow-collection"
  @max_version 1

  @type error ::
          :invalid_json
          | :unknown_format
          | :unsupported_version
          | :malformed
          | {:malformed, term()}

  @doc """
  Parse a JSON envelope string into a list of new `%Collection{}` structs.

  Does NOT persist — see `import_all/1`. Useful when callers want to
  validate first or preview before committing.
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
  Parse + persist. Returns the count of imported collections on success.
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
  Human-friendly explanation for a parse error.
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
    %Collection{
      id: Request.new_id(),
      name: Map.get(map, "name", "Imported"),
      requests:
        map
        |> Map.get("requests", [])
        |> Enum.map(&load_request_with_fresh_id/1)
    }
  end

  defp load_request_with_fresh_id(map) when is_map(map) do
    req = Serializer.load_request(map)
    %{req | id: Request.new_id()}
  end
end
