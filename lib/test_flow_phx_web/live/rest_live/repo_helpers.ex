defmodule TestFlowPhxWeb.RestLive.RepoHelpers do
  @moduledoc """
  Wrappers delgados que cargan collections/history desde el repo y
  sobreviven a condiciones de repo ausente (test env sin storage). Se
  usan para refrescar los assigns correspondientes de la LiveView
  después de escrituras.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TestFlowPhx.UseCases.{Collections, Globals, History}

  @spec load_collections() :: list()
  def load_collections do
    Collections.list()
  catch
    :exit, _ -> []
  end

  @spec refresh_collections(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_collections(socket),
    do: assign(socket, :collections, load_collections())

  @spec load_history() :: list()
  def load_history do
    History.list(50)
  catch
    :exit, _ -> []
  end

  @spec refresh_history(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_history(socket),
    do: assign(socket, :history, load_history())

  @spec load_globals() :: list()
  def load_globals do
    Globals.list()
  catch
    :exit, _ -> []
  end

  @spec refresh_globals(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_globals(socket),
    do: assign(socket, :globals, load_globals())

  @doc """
  Ejecuta una función que muta el repo, tragando `:exit` (GenServer
  ausente) para que los llamadores se mantengan concisos:
  `try_call(fn -> Collections.create(...) end)`. Devuelve el valor de
  la función si tiene éxito, `nil` si el repo no está.
  """
  @spec try_call((-> any())) :: any() | nil
  def try_call(fun) when is_function(fun, 0) do
    fun.()
  catch
    :exit, _ -> nil
  end
end
