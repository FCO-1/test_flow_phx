defmodule TestFlowPhx.Domain.Ports.GrpcCollectionRepo do
  @moduledoc """
  Puerto (behaviour) para persistir colecciones y tabs **gRPC**, aparte del
  store REST.

  Espejo acotado de `TestFlowPhx.Domain.Ports.RequestRepo`: solo colecciones
  y tabs (sin history — el history gRPC quedó diferido en N.7; sin globals —
  los globals son compartidos y viven en el store REST). El adapter de N.11
  escribe a `data/grpc/state.json`
  (`TestFlowPhx.Infrastructure.Storage.GrpcJsonFileRepo`).
  """

  alias TestFlowPhx.Domain.Grpc.{Collection, Request}

  @callback list_collections() :: [Collection.t()]
  @callback upsert_collection(Collection.t()) :: :ok
  @callback delete_collection(String.t()) :: :ok
  @callback clear_collections() :: :ok

  @callback upsert_request_in(String.t(), Request.t()) :: :ok
  @callback delete_request_in(String.t(), String.t()) :: :ok

  @callback list_tabs() :: [Request.t()]
  @callback active_tab_id() :: String.t() | nil
  @callback set_tabs([Request.t()], String.t() | nil) :: :ok

  @callback subscribe() :: :ok
end
