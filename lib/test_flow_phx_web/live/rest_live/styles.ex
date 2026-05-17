defmodule TestFlowPhxWeb.RestLive.Styles do
  @moduledoc """
  Dynamic class-list builders for the REST LiveView. Static class strings
  live inline in the template; this module is for the conditional ones
  that depend on assigns (active states, density tweaks, etc.).
  """

  @spec sidebar_tab(boolean()) :: String.t()
  def sidebar_tab(active?) do
    base = "px-3 py-1.5 text-sm rounded-md transition-colors "

    if active? do
      base <>
        "bg-white dark:bg-zinc-800 border border-zinc-200 dark:border-zinc-700 " <>
        "text-zinc-900 dark:text-zinc-100 font-medium"
    else
      base <>
        "text-zinc-500 dark:text-zinc-400 hover:text-zinc-800 dark:hover:text-zinc-200"
    end
  end
end
