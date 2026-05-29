defmodule TestFlowPhx.UseCases.Grpc.GrpcCollections do
  @moduledoc """
  Use cases para administrar colecciones de requests gRPC guardadas.

  Espejo de `TestFlowPhx.UseCases.Collections` (REST), pero habla con el
  puerto `GrpcCollectionRepo` (store gRPC aparte). Resuelve el adapter
  concreto en runtime vía `Application.fetch_env!/2` (`:grpc_collection_repo`).
  """

  alias TestFlowPhx.Domain.Grpc.{Collection, Request}

  @spec list() :: [Collection.t()]
  def list, do: repo().list_collections()

  @spec create(String.t()) :: Collection.t()
  def create(name) when is_binary(name) do
    collection = %Collection{id: Request.new_id(), name: name, requests: []}
    :ok = repo().upsert_collection(collection)
    collection
  end

  @spec rename(String.t(), String.t()) :: :ok | {:error, :not_found}
  def rename(collection_id, new_name) when is_binary(collection_id) and is_binary(new_name) do
    case Enum.find(list(), &(&1.id == collection_id)) do
      nil -> {:error, :not_found}
      %Collection{} = c -> repo().upsert_collection(%{c | name: new_name})
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(collection_id) when is_binary(collection_id),
    do: repo().delete_collection(collection_id)

  @spec clear() :: :ok
  def clear, do: repo().clear_collections()

  @spec add_request(String.t(), Request.t()) :: Request.t()
  def add_request(collection_id, %Request{} = req) when is_binary(collection_id) do
    req = if req.id in [nil, ""], do: %{req | id: Request.new_id()}, else: req
    :ok = repo().upsert_request_in(collection_id, %{req | collection_id: collection_id})
    %{req | collection_id: collection_id}
  end

  @spec remove_request(String.t(), String.t()) :: :ok
  def remove_request(collection_id, request_id)
      when is_binary(collection_id) and is_binary(request_id),
      do: repo().delete_request_in(collection_id, request_id)

  @doc """
  Reemplaza la lista de variables de una colección gRPC. Mismo patrón
  read-update-upsert que `rename/2`.
  """
  @spec set_variables(String.t(), [Collection.variable()]) :: :ok | {:error, :not_found}
  def set_variables(collection_id, vars)
      when is_binary(collection_id) and is_list(vars) do
    case Enum.find(list(), &(&1.id == collection_id)) do
      nil -> {:error, :not_found}
      %Collection{} = c -> repo().upsert_collection(%{c | variables: vars})
    end
  end

  defp repo, do: Application.fetch_env!(:test_flow_phx, :grpc_collection_repo)
end
