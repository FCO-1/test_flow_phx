defmodule TestFlowPhx.UseCases.SendRequest do
  @moduledoc """
  Application use case: send a Request via the configured HttpExecutor port
  and (optionally) append a summary HistoryEntry via the RequestRepo port.

  The use case is the only seam between the web layer (LiveView) and the
  outside world. It depends on domain entities and ports — never on a
  specific HTTP library or storage backend.
  """

  alias TestFlowPhx.Domain.{HistoryEntry, Request, Response}

  @spec execute(Request.t(), keyword()) :: {Response.t(), HistoryEntry.t() | nil}
  def execute(%Request{} = request, opts \\ []) do
    response = http_executor().send(request, opts)

    history_entry =
      if Keyword.get(opts, :record_history?, true) do
        entry = build_history_entry(request, response)
        maybe_append_history(entry)
        entry
      else
        nil
      end

    {response, history_entry}
  end

  defp build_history_entry(%Request{} = request, %Response{} = response) do
    %HistoryEntry{
      id: Request.new_id(),
      ran_at: DateTime.utc_now(),
      request: request,
      response_status: response.status,
      response_duration_ms: response.duration_ms,
      response_size_bytes: response.size_bytes,
      response_error: response.error
    }
  end

  defp maybe_append_history(entry) do
    repo = request_repo()

    if repo do
      try do
        repo.append_history(entry)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  defp http_executor do
    Application.fetch_env!(:test_flow_phx, :http_executor)
  end

  defp request_repo do
    Application.get_env(:test_flow_phx, :request_repo)
  end
end
