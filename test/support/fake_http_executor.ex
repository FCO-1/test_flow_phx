defmodule TestFlowPhx.Support.FakeHttpExecutor do
  @moduledoc """
  Test adapter implementing `TestFlowPhx.Domain.Ports.HttpExecutor`.

  Lets unit tests stage a canned `%Response{}` and inspect the captured
  request without doing real network I/O. The most-recent request is
  also stored under `:fake_http_last_request` in the Process dictionary
  for assertions.
  """

  @behaviour TestFlowPhx.Domain.Ports.HttpExecutor

  alias TestFlowPhx.Domain.Response

  @stage_key :fake_http_stage
  @last_request_key :fake_http_last_request

  @doc "Stage the response the next `send/2` call should return."
  @spec stage(Response.t()) :: :ok
  def stage(%Response{} = response) do
    Process.put(@stage_key, response)
    :ok
  end

  @doc "Return the request captured by the most recent `send/2` call (or nil)."
  def last_request, do: Process.get(@last_request_key)

  @doc "Reset both the staged response and the last-request capture."
  def reset do
    Process.delete(@stage_key)
    Process.delete(@last_request_key)
    :ok
  end

  @impl true
  def send(request, _opts \\ []) do
    Process.put(@last_request_key, request)

    case Process.get(@stage_key) do
      %Response{} = r -> r
      nil -> %Response{status: 200, headers: [], body: "", duration_ms: 0, size_bytes: 0}
    end
  end
end
