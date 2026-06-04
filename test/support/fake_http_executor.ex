defmodule TestFlowPhx.Support.FakeHttpExecutor do
  @moduledoc """
  Test adapter implementing `TestFlowPhx.Domain.Ports.HttpExecutor`.

  Lets unit tests stage a canned `%Response{}` and inspect the captured
  request without doing real network I/O.

  Storage backend: `Application.put_env` rather than the process
  dictionary, so when LiveView tests run the executor inside a
  `Task.Supervisor.async_nolink` (different process) the staged response
  is still visible. Requires `async: false` on tests that stage values.
  """

  @behaviour TestFlowPhx.Domain.Ports.HttpExecutor

  alias TestFlowPhx.Domain.Rest.Response

  @stage_key :fake_http_stage
  @last_request_key :fake_http_last_request

  @doc "Stage the response the next `send/2` call should return."
  @spec stage(Response.t()) :: :ok
  def stage(%Response{} = response) do
    Application.put_env(:test_flow_phx, @stage_key, response)
    :ok
  end

  @doc "Return the request captured by the most recent `send/2` call (or nil)."
  def last_request, do: Application.get_env(:test_flow_phx, @last_request_key)

  @doc "Reset both the staged response and the last-request capture."
  def reset do
    Application.delete_env(:test_flow_phx, @stage_key)
    Application.delete_env(:test_flow_phx, @last_request_key)
    :ok
  end

  @impl true
  def send(request, _opts \\ []) do
    Application.put_env(:test_flow_phx, @last_request_key, request)

    case Application.get_env(:test_flow_phx, @stage_key) do
      %Response{} = r -> r
      nil -> %Response{status: 200, headers: [], body: "", duration_ms: 0, size_bytes: 0}
    end
  end
end
