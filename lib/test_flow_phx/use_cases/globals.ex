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

  @doc """
  Upsert de una variable global por nombre: si ya existe `name`, le pisa el
  valor y la deja habilitada; si no, la agrega. Usado por el encadenado de
  respuestas (capturas) para refrescar p.ej. `{{token}}` tras cada login.
  """
  @spec put(String.t(), String.t()) :: :ok
  def put(name, value) when is_binary(name) and is_binary(value) do
    vars = list()

    updated =
      if Enum.any?(vars, &(&1.name == name)) do
        Enum.map(vars, fn v ->
          if v.name == name, do: %{v | value: value, enabled: true}, else: v
        end)
      else
        vars ++ [%{name: name, value: value, enabled: true}]
      end

    replace(updated)
  end

  defp repo, do: Application.fetch_env!(:test_flow_phx, :request_repo)
end
