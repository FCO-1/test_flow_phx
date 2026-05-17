defmodule TestFlowPhxWeb.RestLive.Hotkeys do
  @moduledoc """
  Maps a `phx-window-keydown` payload into a high-level action atom.

  Browser-reserved combos (Ctrl+T, Ctrl+W) are avoided in favor of
  Alt+N / Alt+W. Ctrl/Cmd+Enter sends the active request and is allowed
  to fire from inside an input.
  """

  @type action :: :send | :new_tab | :close_tab | :none

  @spec classify(map()) :: action()
  def classify(%{"key" => key} = p) do
    ctrl_or_meta = truthy(p["ctrlKey"]) or truthy(p["metaKey"])
    alt = truthy(p["altKey"])

    cond do
      key == "Enter" and ctrl_or_meta -> :send
      alt and key in ["n", "N"] -> :new_tab
      alt and key in ["w", "W"] -> :close_tab
      true -> :none
    end
  end

  def classify(_), do: :none

  # JS DOM events arrive as JSON booleans — sometimes the wire encodes
  # them as the strings "true"/"false". Normalize both.
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false
end
