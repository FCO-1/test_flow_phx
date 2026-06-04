defmodule TestFlowPhx.UseCases.Globals do
  @moduledoc """
  Variables globales del workspace. Persisten en `state.json` y aplican a
  cualquier request enviado, salvo que la colección de la tab tenga una
  variable con el mismo nombre (que entonces gana).

  Reemplazo total en cada save: el editor de UI maneja la lista completa,
  no hay upsert por fila individual. Mantiene el contrato del repo
  minimal (un callback `replace_globals/1` en lugar de N variantes).
  """

  alias TestFlowPhx.Domain.Collection

  @spec list() :: [Collection.variable()]
  def list, do: repo().list_globals()

  @spec replace([Collection.variable()]) :: :ok
  def replace(vars) when is_list(vars), do: repo().replace_globals(vars)

  defp repo, do: Application.fetch_env!(:test_flow_phx, :request_repo)
end
