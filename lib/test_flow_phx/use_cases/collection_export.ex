defmodule TestFlowPhx.UseCases.CollectionExport do
  @moduledoc """
  Builders puros que convierten structs `%Collection{}` en nuestro
  sobre JSON portable.

  Formato:

      {
        "format": "testflow-collection",
        "version": 1,
        "exported_at": "2026-05-17T18:30:00Z",
        "collections": [
          {
            "name": "...",
            "requests": [<mapa del request producido por Serializer>, ...]
          },
          ...
        ]
      }

  A propósito simple y auto-descriptivo — NO es compatible con Postman.
  Quita los IDs internos para que importar el archivo no colisione con
  registros existentes (el importador asigna IDs nuevos al cargar).
  """

  alias TestFlowPhx.Domain.Collection
  alias TestFlowPhx.Infrastructure.Storage.Serializer

  @format "testflow-collection"
  @version 1

  @spec build([Collection.t()]) :: map()
  def build(collections) when is_list(collections) do
    %{
      "format" => @format,
      "version" => @version,
      "exported_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "collections" => Enum.map(collections, &dump_collection_without_ids/1)
    }
  end

  @spec build(Collection.t()) :: map()
  def build(%Collection{} = c), do: build([c])

  @spec to_json([Collection.t()] | Collection.t()) :: String.t()
  def to_json(arg) do
    arg
    |> build()
    |> Jason.encode_to_iodata!(pretty: true)
    |> IO.iodata_to_binary()
  end

  @doc """
  Nombre de archivo razonable para un export — slug del nombre de la
  colección más fecha. Para exports multi-colección pasa `nil` y se usa
  un nombre genérico.
  """
  @spec suggested_filename(String.t() | nil) :: String.t()
  def suggested_filename(name) do
    base = if is_binary(name) and name != "", do: slugify(name), else: "testflow-collections"
    date = Date.utc_today() |> Date.to_iso8601()
    "#{base}-#{date}.json"
  end

  defp dump_collection_without_ids(%Collection{} = c) do
    %{
      "name" => c.name,
      "requests" =>
        Enum.map(c.requests, fn r ->
          r |> Serializer.dump_request() |> Map.delete("id")
        end)
    }
  end

  defp slugify(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "collection"
      slug -> slug
    end
  end
end
