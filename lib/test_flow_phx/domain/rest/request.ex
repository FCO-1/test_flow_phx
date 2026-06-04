defmodule TestFlowPhx.Domain.Rest.Request do
  @moduledoc """
  Entidad de dominio: borrador de un request HTTP que el usuario está
  editando o por enviar.

  Datos puros + helpers de construcción. Sin I/O, sin dependencias del
  framework.
  """

  @type method :: String.t()
  @type body_type :: :none | :json | :raw | :form_urlencoded | :multipart
  @type kv_row :: %{key: String.t(), value: String.t(), enabled: boolean()}
  @type form_row :: %{
          key: String.t(),
          value: String.t(),
          enabled: boolean(),
          type: :text | :file,
          file_path: String.t() | nil
        }
  @type auth ::
          %{type: :none}
          | %{type: :bearer, token: String.t()}
          | %{type: :api_key, key: String.t(), value: String.t(), in: :header | :query}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          method: method(),
          url: String.t(),
          query_params: [kv_row()],
          headers: [kv_row()],
          body_type: body_type(),
          body_text: String.t(),
          body_form: [form_row()],
          auth: auth(),
          collection_id: String.t() | nil
        }

  defstruct id: nil,
            name: "Untitled",
            method: "GET",
            url: "",
            query_params: [],
            headers: [],
            body_type: :none,
            body_text: "",
            body_form: [],
            auth: %{type: :none},
            collection_id: nil

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ %{}) do
    struct(__MODULE__, normalize(attrs))
  end

  @spec new_id() :: String.t()
  def new_id, do: random_id()

  @spec empty_kv() :: kv_row()
  def empty_kv, do: %{key: "", value: "", enabled: true}

  @spec empty_form_row() :: form_row()
  def empty_form_row,
    do: %{key: "", value: "", enabled: true, type: :text, file_path: nil}

  defp normalize(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize(attrs) when is_map(attrs), do: attrs

  defp random_id do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
