defmodule TestFlowPhx.Domain.HistoryEntry do
  @moduledoc """
  Domain entity: an immutable snapshot of a sent request and a summary of its
  response. The full response body is intentionally NOT stored here so the
  persisted history file stays small.
  """

  alias TestFlowPhx.Domain.Request

  @type t :: %__MODULE__{
          id: String.t() | nil,
          ran_at: DateTime.t() | nil,
          request: Request.t() | nil,
          response_status: non_neg_integer() | nil,
          response_duration_ms: non_neg_integer(),
          response_size_bytes: non_neg_integer(),
          response_error: map() | nil
        }

  defstruct id: nil,
            ran_at: nil,
            request: nil,
            response_status: nil,
            response_duration_ms: 0,
            response_size_bytes: 0,
            response_error: nil
end
