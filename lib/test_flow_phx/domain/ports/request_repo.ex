defmodule TestFlowPhx.Domain.Ports.RequestRepo do
  @moduledoc """
  Port (behaviour) for persisting collections, history and open tabs.

  Phase 1 adapter writes to a local JSON file
  (`TestFlowPhx.Infrastructure.Storage.JsonFileRepo`). A future SQLite/Ecto
  adapter could replace it without touching domain or use cases.
  """

  alias TestFlowPhx.Domain.{Collection, HistoryEntry, Request}

  @callback list_collections() :: [Collection.t()]
  @callback upsert_collection(Collection.t()) :: :ok
  @callback delete_collection(String.t()) :: :ok
  @callback clear_collections() :: :ok

  @callback upsert_request_in(String.t(), Request.t()) :: :ok
  @callback delete_request_in(String.t(), String.t()) :: :ok

  @callback list_history(pos_integer()) :: [HistoryEntry.t()]
  @callback append_history(HistoryEntry.t()) :: :ok
  @callback clear_history() :: :ok

  @callback list_tabs() :: [Request.t()]
  @callback active_tab_id() :: String.t() | nil
  @callback set_tabs([Request.t()], String.t() | nil) :: :ok

  @callback subscribe() :: :ok
end
