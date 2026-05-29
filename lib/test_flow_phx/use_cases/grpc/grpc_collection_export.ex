defmodule TestFlowPhx.UseCases.Grpc.GrpcCollectionExport do
  @moduledoc """
  Builders puros que convierten `%Grpc.Collection{}` en nuestro sobre JSON
  portable para colecciones **gRPC**.

  Formato (v2):

      {
        "format": "testflow-grpc-collection",
        "version": 2,
        "exported_at": "2026-05-29T18:30:00Z",
        "collections": [
          {
            "name": "...",
            "requests": [
              {
                "name": "...", "target": "...", "service": "...", "method": "...",
                "proto_set": "<nombre del proto-set>",   // por NOMBRE, no por id
                "entry_file": "donavida/auth/v1/auth.proto",
                "metadata": [...], "body_text": "..."
              }, ...
            ],
            "variables": [{"name": "...", "value": "...", "enabled": true}, ...]
          }, ...
        ]
      }

  **El export NO incluye los archivos `.proto`** (como Postman): lleva los
  requests (target/service/method/body/metadata), las variables de la colección
  y una **referencia al proto-set por nombre** (+ el `entry_file`). Al importar,
  si existe un proto-set local con ese nombre se re-enlaza; si no, el request
  queda sin proto hasta que se suba el set. No se exportan rutas locales ni ids.

  Espejo de `UseCases.CollectionExport` (REST), con un `format` **distinto** para
  que un importador no acepte el sobre del otro protocolo.
  """

  alias TestFlowPhx.Domain.Grpc.Collection
  alias TestFlowPhx.Infrastructure.Storage.GrpcSerializer
  alias TestFlowPhx.UseCases.Grpc.GrpcProtoSets

  @format "testflow-grpc-collection"
  @version 2

  # Campos locales/no portables que el export omite del request.
  @local_fields ["id", "collection_id", "proto_set_id", "proto_paths", "import_paths"]

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
      "requests" => Enum.map(c.requests, &dump_request_portable/1),
      "variables" => GrpcSerializer.dump_variables(c.variables)
    }
  end

  # Reusa la serialización de GrpcSerializer (incl. metadata) y la hace portable:
  # quita rutas/ids locales y añade el proto-set por NOMBRE.
  defp dump_request_portable(r) do
    r
    |> GrpcSerializer.dump_request()
    |> Map.drop(@local_fields)
    |> Map.put("proto_set", proto_set_name(r.proto_set_id))
  end

  defp proto_set_name(nil), do: nil

  defp proto_set_name(id) do
    case GrpcProtoSets.get(id) do
      %{name: name} -> name
      _ -> nil
    end
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
