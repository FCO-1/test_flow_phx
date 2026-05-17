defmodule TestFlowPhxWeb.RestLive.Parsers do
  @moduledoc """
  Small input parsers used by the LiveView event handlers. Centralised
  here so the index module reads as event-routing only.
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
  Parses the save-modal target field: a collection id (binary) or the
  sentinel `:new` for "create a new collection".
  """
  @spec save_target(String.t() | nil) :: :new | String.t()
  def save_target("new"), do: :new
  def save_target(nil), do: :new
  def save_target(""), do: :new
  def save_target(id) when is_binary(id), do: id

  @doc "Suggests a default name for a request being saved."
  @spec default_request_name(map()) :: String.t()
  def default_request_name(%{name: name}) when name not in [nil, "", "Untitled"], do: name
  def default_request_name(%{method: m, url: url}) when url != "", do: "#{m} #{url}"
  def default_request_name(_), do: "New Request"

  @doc "Spanish pluralisation helper for the import flash."
  @spec collection_word(non_neg_integer()) :: String.t()
  def collection_word(1), do: "colección"
  def collection_word(_), do: "colecciones"
end
