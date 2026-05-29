defmodule TestFlowPhx.UseCases.Grpc.GrpcCollectionExport do
  @moduledoc """
  Builders puros que convierten `%Grpc.Collection{}` en nuestro sobre JSON
  portable para colecciones **gRPC**.

  Formato:

      {
        "format": "testflow-grpc-collection",
        "version": 1,
        "exported_at": "2026-05-29T18:30:00Z",
        "collections": [
          {
            "name": "...",
            "requests": [<mapa del request gRPC producido por GrpcSerializer>, ...],
            "variables": [{"name": "...", "value": "...", "enabled": true}, ...]
          },
          ...
        ]
      }

  Espejo de `UseCases.CollectionExport` (REST), pero con un `format` **distinto**:
  el shape de un request gRPC (target/service/method/proto_paths/metadata) no es
  compatible con el REST (method/url/headers/auth/body_type), así que el sobre se
  marca aparte para que el importador gRPC rechace un export REST (y viceversa).

  Quita los IDs internos para que importar no colisione con registros existentes
  (el importador asigna IDs nuevos al cargar).
  """

  alias TestFlowPhx.Domain.Grpc.Collection
  alias TestFlowPhx.Infrastructure.Storage.GrpcSerializer

  @format "testflow-grpc-collection"
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
  Nombre de archivo razonable para un export — slug del nombre de la colección
  más fecha. Para exports multi-colección pasa `nil`.
  """
  @spec suggested_filename(String.t() | nil) :: String.t()
  def suggested_filename(name) do
    base = if is_binary(name) and name != "", do: slugify(name), else: "testflow-grpc-collections"
    date = Date.utc_today() |> Date.to_iso8601()
    "#{base}-#{date}.json"
  end

  defp dump_collection_without_ids(%Collection{} = c) do
    %{
      "name" => c.name,
      "requests" =>
        Enum.map(c.requests, fn r ->
          r
          |> GrpcSerializer.dump_request()
          |> Map.drop(["id", "collection_id"])
        end),
      "variables" => GrpcSerializer.dump_variables(c.variables)
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
