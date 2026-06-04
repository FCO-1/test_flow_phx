defmodule TestFlowPhx.Domain.HistoryEntry do
  @moduledoc """
  Entidad de dominio: una instantánea inmutable de un request enviado y
  el resumen de su respuesta. El body completo de la respuesta NO se
  almacena aquí a propósito, para que el archivo de historial persistido
  se mantenga pequeño (el body vive como archivo aparte referenciado por
  `result_file`).
  """

  alias TestFlowPhx.Domain.Rest.Request

  @type t :: %__MODULE__{
          id: String.t() | nil,
          ran_at: DateTime.t() | nil,
          request: Request.t() | nil,
          response_status: non_neg_integer() | nil,
          response_duration_ms: non_neg_integer(),
          response_size_bytes: non_neg_integer(),
          response_error: map() | nil,
          result_file: String.t() | nil
        }

  defstruct id: nil,
            ran_at: nil,
            request: nil,
            response_status: nil,
            response_duration_ms: 0,
            response_size_bytes: 0,
            response_error: nil,
            result_file: nil
end
