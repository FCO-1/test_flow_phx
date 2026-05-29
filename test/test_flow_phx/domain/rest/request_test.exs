defmodule TestFlowPhx.Domain.Rest.RequestTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Domain.Rest.Request

  describe "new/1" do
    test "builds a default GET request with sane defaults" do
      req = Request.new()

      assert %Request{} = req
      assert req.method == "GET"
      assert req.url == ""
      assert req.body_type == :none
      assert req.headers == []
      assert req.query_params == []
      assert req.auth == %{type: :none}
    end

    test "accepts a keyword list of attributes" do
      req = Request.new(method: "POST", url: "https://example.com", body_type: :json)

      assert req.method == "POST"
      assert req.url == "https://example.com"
      assert req.body_type == :json
    end

    test "accepts a map of attributes" do
      req = Request.new(%{name: "ping", method: "HEAD"})

      assert req.name == "ping"
      assert req.method == "HEAD"
    end
  end

  describe "new_id/0" do
    test "produces non-empty url-safe ids" do
      id = Request.new_id()

      assert is_binary(id)
      assert byte_size(id) > 0
      refute String.contains?(id, "/")
      refute String.contains?(id, "+")
    end

    test "produces distinct ids" do
      assert Request.new_id() != Request.new_id()
    end
  end

  describe "row helpers" do
    test "empty_kv/0 returns an enabled empty row" do
      assert Request.empty_kv() == %{key: "", value: "", enabled: true}
    end

    test "empty_form_row/0 defaults to text and no file" do
      row = Request.empty_form_row()

      assert row.type == :text
      assert row.enabled == true
      assert row.file_path == nil
    end
  end
end
