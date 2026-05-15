defmodule TestFlowPhx.UseCases.Collections do
  @moduledoc """
  Use cases for managing collections of saved requests.

  Talks to the world via the `RequestRepo` port; resolves the concrete
  adapter at runtime via `Application.fetch_env!/2`.
  """

  alias TestFlowPhx.Domain.{Collection, Request}

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

  @spec add_request(String.t(), Request.t()) :: Request.t()
  def add_request(collection_id, %Request{} = req) when is_binary(collection_id) do
    req = if req.id in [nil, ""], do: %{req | id: Request.new_id()}, else: req
    :ok = repo().upsert_request_in(collection_id, req)
    req
  end

  @spec remove_request(String.t(), String.t()) :: :ok
  def remove_request(collection_id, request_id)
      when is_binary(collection_id) and is_binary(request_id),
      do: repo().delete_request_in(collection_id, request_id)

  defp repo, do: Application.fetch_env!(:test_flow_phx, :request_repo)
end
