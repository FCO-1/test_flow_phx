defmodule TestFlowPhx.Domain.Grpc.HistoryEntry do
  @moduledoc """
  Entidad de dominio: instantánea inmutable de un request **gRPC** enviado y el
  resumen de su respuesta. Espejo de `Domain.HistoryEntry` (REST), pero propio del
  protocolo gRPC (embebe un `Grpc.Request` y resume la respuesta gRPC).

  El cuerpo completo de la respuesta NO se guarda acá: vive como archivo aparte
  (`result_file`, en `data/grpc/<fecha>/<epoch>.json`) para que el `state.json`
  gRPC se mantenga chico. Para streaming, ese archivo contiene la lista de mensajes
  y `message_count` su cantidad.
  """

  alias TestFlowPhx.Domain.Grpc.Request

  @type t :: %__MODULE__{
          id: String.t() | nil,
          ran_at: DateTime.t() | nil,
          request: Request.t() | nil,
          response_status: non_neg_integer() | nil,
          response_message: String.t() | nil,
          streaming?: boolean(),
          message_count: non_neg_integer(),
          response_duration_ms: non_neg_integer(),
          response_error: map() | nil,
          result_file: String.t() | nil
        }

  defstruct id: nil,
            ran_at: nil,
            request: nil,
            response_status: nil,
            response_message: nil,
            streaming?: false,
            message_count: 0,
            response_duration_ms: 0,
            response_error: nil,
            result_file: nil
end
