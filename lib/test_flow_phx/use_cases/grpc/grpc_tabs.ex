defmodule TestFlowPhx.UseCases.Grpc.GrpcTabs do
  @moduledoc """
  Use cases para el estado de tabs abiertas en el tester gRPC (persistido
  para que un reload del navegador restaure el workspace).

  Espejo de `TestFlowPhx.UseCases.Tabs` (REST), pero habla con el puerto
  `GrpcCollectionRepo` (store gRPC aparte, `data/grpc/state.json`). El slot
  `tabs`/`active_tab_id` ya existía en el documento desde N.11a; esto solo lo
  cablea a la UI.
  """

  alias TestFlowPhx.Domain.Grpc.Request

  @spec list() :: [Request.t()]
  def list, do: repo().list_tabs()

  @spec active_id() :: String.t() | nil
  def active_id, do: repo().active_tab_id()

  @spec save([Request.t()], String.t() | nil) :: :ok
  def save(tabs, active_id) when is_list(tabs),
    do: repo().set_tabs(tabs, active_id)

  defp repo, do: Application.fetch_env!(:test_flow_phx, :grpc_collection_repo)
end
