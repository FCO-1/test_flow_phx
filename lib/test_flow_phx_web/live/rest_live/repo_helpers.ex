defmodule TestFlowPhxWeb.RestLive.RepoHelpers do
  @moduledoc """
  Thin wrappers that load collections/history from the repo while
  surviving missing-repo conditions (test env without storage). Used to
  refresh the corresponding LiveView assigns after writes.
  """

  import Phoenix.Component, only: [assign: 3]

  alias TestFlowPhx.UseCases.{Collections, History}

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

  @doc """
  Run a repo-mutating function, swallowing `:exit` (missing GenServer)
  so callers can stay terse: `try_call(fn -> Collections.create(...) end)`.
  Returns the function's value on success, `nil` on missing repo.
  """
  @spec try_call((-> any())) :: any() | nil
  def try_call(fun) when is_function(fun, 0) do
    fun.()
  catch
    :exit, _ -> nil
  end
end
