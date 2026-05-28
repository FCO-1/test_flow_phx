defmodule TestFlowPhx.Domain.Ports.RequestRepo do
  @moduledoc """
  Puerto (behaviour) para persistir colecciones, historial y tabs
  abiertas.

  El adapter de Fase 1 escribe a un archivo JSON local
  (`TestFlowPhx.Infrastructure.Storage.JsonFileRepo`). Un adapter futuro
  basado en SQLite/Ecto podría reemplazarlo sin tocar el dominio ni los
  use cases.
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

  @callback list_globals() :: [Collection.variable()]
  @callback replace_globals([Collection.variable()]) :: :ok

  @callback subscribe() :: :ok
end
