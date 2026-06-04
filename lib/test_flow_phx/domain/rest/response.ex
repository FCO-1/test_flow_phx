defmodule TestFlowPhx.Domain.Rest.Response do
  @moduledoc """
  Entidad de dominio: el resultado de ejecutar un request. Siempre se
  construye, nunca se lanza como excepción — los fallos de red y de
  parsing se capturan en el campo `:error`.
  """

  @type error ::
          %{type: :invalid_json, message: String.t()}
          | %{type: :invalid_request, message: String.t()}
          | %{type: :timeout, message: String.t()}
          | %{type: :network, message: String.t()}
          | %{type: :unknown, message: String.t()}

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          body_decoded: term() | nil,
          duration_ms: non_neg_integer(),
          size_bytes: non_neg_integer(),
          error: error() | nil
        }

  defstruct status: nil,
            headers: [],
            body: nil,
            body_decoded: nil,
            duration_ms: 0,
            size_bytes: 0,
            error: nil
end
