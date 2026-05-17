defmodule TestFlowPhxWeb.RestLive.Hotkeys do
  @moduledoc """
  Mapea un payload de `phx-window-keydown` a un atom de acción de alto
  nivel.

  Las combos reservadas por el navegador (Ctrl+T, Ctrl+W) se evitan en
  favor de Alt+N / Alt+W. Ctrl/Cmd+Enter envía el request activo y se
  permite que dispare desde dentro de un input.
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

  # Los eventos DOM JS llegan como booleanos JSON — a veces el wire los
  # codifica como strings "true"/"false". Normalizamos ambos.
  defp truthy(true), do: true
  defp truthy("true"), do: true
  defp truthy(_), do: false
end
