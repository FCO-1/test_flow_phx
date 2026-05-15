defmodule TestFlowPhx.Domain.Collection do
  @moduledoc """
  Domain entity: a flat (Phase 1) folder grouping saved Requests.
  """

  alias TestFlowPhx.Domain.Request

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          requests: [Request.t()]
        }

  defstruct id: nil, name: "", requests: []
end
