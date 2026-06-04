defmodule TestFlowPhx.Domain.Grpc.Response do
  @moduledoc """
  Entidad de dominio: resultado de ejecutar un request gRPC. Siempre se
  construye, nunca se lanza — los fallos (carga de proto, JSON inválido,
  transporte, grpc-status != 0) se capturan en `:error`.

  - **unary**: `body_decoded` trae el mensaje de respuesta como mapa
    JSON-amigable; `messages` queda `[]`.
  - **server streaming**: `messages` acumula cada mensaje decodificado en orden;
    `body_decoded` queda `nil` y `streaming?` es `true`.

  `status`/`message` son el `grpc-status` numérico y el `grpc-message`. En éxito
  `status` es `0`. Los campos `headers`/`trailers`/`body_raw` se reservan para
  exponer metadata cruda más adelante (el motor aún no la surface en éxito).
  """

  @type error :: %{
          type: :proto_load | :invalid_json | :invalid_request | :transport | :grpc | :unknown,
          message: String.t(),
          code: non_neg_integer() | atom() | nil
        }

  @type t :: %__MODULE__{
          status: non_neg_integer() | nil,
          message: String.t() | nil,
          headers: [{String.t(), String.t()}],
          trailers: [{String.t(), String.t()}],
          body_decoded: term() | nil,
          body_raw: binary() | nil,
          messages: [term()],
          streaming?: boolean(),
          duration_ms: non_neg_integer(),
          error: error() | nil
        }

  defstruct status: nil,
            message: nil,
            headers: [],
            trailers: [],
            body_decoded: nil,
            body_raw: nil,
            messages: [],
            streaming?: false,
            duration_ms: 0,
            error: nil
end
