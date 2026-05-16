defmodule TestFlowPhx.UseCases.SendRequestTest do
  @moduledoc """
  Unit tests for the `SendRequest` use case.

  Uses `TestFlowPhx.Support.FakeHttpExecutor` (wired via config/test.exs)
  so no network I/O happens. Tests stage a `%Response{}` and verify that
  the use case returns it plus a populated `%HistoryEntry{}`.
  """

  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.{HistoryEntry, Request, Response}
  alias TestFlowPhx.Support.FakeHttpExecutor
  alias TestFlowPhx.UseCases.SendRequest

  setup do
    FakeHttpExecutor.reset()
    :ok
  end

  test "delegates to the configured HttpExecutor and returns its response" do
    FakeHttpExecutor.stage(%Response{
      status: 200,
      headers: [{"content-type", "application/json"}],
      body: ~s({"ok":true}),
      body_decoded: %{"ok" => true},
      duration_ms: 7,
      size_bytes: 11
    })

    req = Request.new(method: "GET", url: "https://example.test/ping")
    {response, _history} = SendRequest.execute(req, record_history?: false)

    assert response.status == 200
    assert response.body_decoded == %{"ok" => true}
    assert FakeHttpExecutor.last_request().url == "https://example.test/ping"
  end

  test "builds a HistoryEntry snapshot when record_history? is true (default) and repo is absent" do
    FakeHttpExecutor.stage(%Response{status: 201, duration_ms: 3, size_bytes: 0})

    req = Request.new(method: "POST", url: "https://example.test/items")
    {_response, history} = SendRequest.execute(req)

    assert %HistoryEntry{} = history
    assert history.response_status == 201
    assert history.response_duration_ms == 3
    assert history.request.method == "POST"
    assert is_struct(history.ran_at, DateTime)
  end

  test "returns nil history when record_history? is false" do
    FakeHttpExecutor.stage(%Response{status: 200})

    req = Request.new(method: "GET", url: "https://example.test/")
    {_response, history} = SendRequest.execute(req, record_history?: false)

    assert is_nil(history)
  end

  test "propagates response errors without raising" do
    FakeHttpExecutor.stage(%Response{
      error: %{type: :timeout, message: "receive_timeout"}
    })

    req = Request.new(method: "GET", url: "https://example.test/slow")
    {response, history} = SendRequest.execute(req)

    assert response.error.type == :timeout
    assert history.response_error.type == :timeout
    assert is_nil(history.response_status)
    assert is_nil(history.result_file)
  end

  describe "body persistence" do
    test "writes the response body to disk and points result_file at it" do
      FakeHttpExecutor.stage(%Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s({"persisted":true}),
        body_decoded: %{"persisted" => true},
        duration_ms: 4,
        size_bytes: 18
      })

      req = Request.new(method: "GET", url: "https://example.test/save")
      {_response, history} = SendRequest.execute(req)

      assert is_binary(history.result_file)
      assert String.ends_with?(history.result_file, ".json")
      assert File.exists?(history.result_file)
      assert File.read!(history.result_file) == ~s({"persisted":true})
    end

    test "skips persistence when persist_body? is false" do
      FakeHttpExecutor.stage(%Response{
        status: 200,
        headers: [{"content-type", "application/json"}],
        body: ~s({"x":1})
      })

      req = Request.new(method: "GET", url: "https://example.test/skip")
      {_response, history} = SendRequest.execute(req, persist_body?: false)

      assert is_nil(history.result_file)
    end

    test "skips persistence on empty body" do
      FakeHttpExecutor.stage(%Response{status: 204, body: "", duration_ms: 1, size_bytes: 0})

      req = Request.new(method: "DELETE", url: "https://example.test/x")
      {_response, history} = SendRequest.execute(req)

      assert is_nil(history.result_file)
    end
  end
end
