defmodule TestFlowPhx.UseCases.Tabs do
  @moduledoc """
  Use cases para el estado de tabs abiertas (persistido para que un
  reload del navegador restaure el workspace).
  """

  alias TestFlowPhx.Domain.Request

  @spec list() :: [Request.t()]
  def list, do: repo().list_tabs()

  @spec active_id() :: String.t() | nil
  def active_id, do: repo().active_tab_id()

  @spec save([Request.t()], String.t() | nil) :: :ok
  def save(tabs, active_id) when is_list(tabs),
    do: repo().set_tabs(tabs, active_id)

  defp repo, do: Application.fetch_env!(:test_flow_phx, :request_repo)
end
