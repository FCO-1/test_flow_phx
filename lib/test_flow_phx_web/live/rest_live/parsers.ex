defmodule TestFlowPhxWeb.RestLive.Parsers do
  @moduledoc """
  Parsers pequeños de input usados por los event handlers de la
  LiveView. Centralizados aquí para que el módulo `index` se lea solo
  como ruteo de eventos.
  """

  @spec theme(String.t() | any()) :: :light | :dark | :system
  def theme("light"), do: :light
  def theme("dark"), do: :dark
  def theme(_), do: :system

  @spec density(String.t() | any()) :: :compact | :fluid | :standard
  def density("compact"), do: :compact
  def density("fluid"), do: :fluid
  def density(_), do: :standard

  @doc """
  Parsea el campo target del save-modal: un id de colección (binary) o
  el sentinel `:new` para "crear una colección nueva".
  """
  @spec save_target(String.t() | nil) :: :new | String.t()
  def save_target("new"), do: :new
  def save_target(nil), do: :new
  def save_target(""), do: :new
  def save_target(id) when is_binary(id), do: id

  @doc "Sugiere un nombre default para un request que se está guardando."
  @spec default_request_name(map()) :: String.t()
  def default_request_name(%{name: name}) when name not in [nil, "", "Untitled"], do: name
  def default_request_name(%{method: m, url: url}) when url != "", do: "#{m} #{url}"
  def default_request_name(_), do: "New Request"

  @doc "Helper de pluralización en español para el flash de import."
  @spec collection_word(non_neg_integer()) :: String.t()
  def collection_word(1), do: "colección"
  def collection_word(_), do: "colecciones"
end
