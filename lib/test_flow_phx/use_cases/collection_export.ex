defmodule TestFlowPhx.UseCases.CollectionExport do
  @moduledoc """
  Pure builders that turn `%Collection{}` structs into our portable
  JSON envelope.

  Format:

      {
        "format": "testflow-collection",
        "version": 1,
        "exported_at": "2026-05-17T18:30:00Z",
        "collections": [
          {
            "name": "...",
            "requests": [<Serializer-dumped request map>, ...]
          },
          ...
        ]
      }

  Intentionally simple and self-describing — not Postman-compatible.
  Strips internal IDs so importing a file does not collide with existing
  records (the importer assigns fresh IDs at load time).
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
  Reasonable filename for an export — slugified collection name plus
  date stamp. For multi-collection exports pass `nil` and a generic
  name will be used.
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
