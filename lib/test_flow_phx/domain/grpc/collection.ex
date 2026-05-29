defmodule TestFlowPhx.Domain.Grpc.Collection do
  @moduledoc """
  Entidad de dominio: una colección plana de requests gRPC guardadas.

  Espejo de `TestFlowPhx.Domain.Collection` (REST) pero con payloads
  `Grpc.Request`. Vive en su propio store (`data/grpc/state.json`), aislado
  del REST — ver decisión N.11 en `docs/planes/fase-n-grpc.md`.

  `variables` son las collection-vars gRPC; los `globals` siguen siendo
  compartidos y viven en el store REST (`data/state.json`).
  """

  alias TestFlowPhx.Domain.Grpc.Request

  @type variable :: %{name: String.t(), value: String.t(), enabled: boolean()}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          requests: [Request.t()],
          variables: [variable()]
        }

  defstruct id: nil, name: "", requests: [], variables: []
end
