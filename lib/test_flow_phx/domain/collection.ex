defmodule TestFlowPhx.Domain.Collection do
  @moduledoc """
  Entidad de dominio: una carpeta plana (Fase 1) que agrupa Requests
  guardadas. Sin carpetas anidadas todavía.
  """

  alias TestFlowPhx.Domain.Request

  @type variable :: %{name: String.t(), value: String.t(), enabled: boolean()}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          requests: [Request.t()],
          variables: [variable()]
        }

  defstruct id: nil, name: "", requests: [], variables: []
end
