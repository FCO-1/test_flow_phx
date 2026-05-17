defmodule TestFlowPhx.UseCases.History do
  @moduledoc """
  Use cases sobre el historial de requests (con tope, append-only desde
  el punto de vista del llamador).
  """

  alias TestFlowPhx.Domain.HistoryEntry

  @spec list(pos_integer()) :: [HistoryEntry.t()]
  def list(limit \\ 50), do: repo().list_history(limit)

  @spec append(HistoryEntry.t()) :: :ok
  def append(%HistoryEntry{} = entry), do: repo().append_history(entry)

  @spec clear() :: :ok
  def clear, do: repo().clear_history()

  defp repo, do: Application.fetch_env!(:test_flow_phx, :request_repo)
end
