defmodule TestFlowPhxWeb.RequestParamsTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Domain.Request
  alias TestFlowPhxWeb.RequestParams

  setup do
    {:ok, base: Request.new(method: "GET", url: "https://x.test", body_type: :none)}
  end

  describe "scalar fields" do
    test "updates method and url from form params", %{base: base} do
      out = RequestParams.from_form(%{"method" => "POST", "url" => "https://y/"}, base)
      assert out.method == "POST"
      assert out.url == "https://y/"
    end

    test "falls back to base when a key is missing", %{base: base} do
      out = RequestParams.from_form(%{"url" => "https://z/"}, base)
      assert out.method == "GET"
      assert out.url == "https://z/"
    end

    test "method falls back to base when blank", %{base: base} do
      out = RequestParams.from_form(%{"method" => ""}, base)
      assert out.method == "GET"
    end
  end

  describe "body" do
    test "updates body_type and body_text", %{base: base} do
      out =
        RequestParams.from_form(
          %{"body_type" => "json", "body_text" => ~s({"k":1})},
          base
        )

      assert out.body_type == :json
      assert out.body_text == ~s({"k":1})
    end

    test "ignores unknown body_type and keeps base", %{base: base} do
      out = RequestParams.from_form(%{"body_type" => "yaml"}, base)
      assert out.body_type == :none
    end
  end

  describe "kv rows" do
    test "parses indexed query_params preserving order", %{base: base} do
      params = %{
        "query_params" => %{
          "0" => %{"key" => "a", "value" => "1", "enabled" => "true"},
          "1" => %{"key" => "b", "value" => "2", "enabled" => "false"}
        }
      }

      out = RequestParams.from_form(params, base)

      assert out.query_params == [
               %{key: "a", value: "1", enabled: true},
               %{key: "b", value: "2", enabled: false}
             ]
    end

    test "parses headers same as query_params", %{base: base} do
      params = %{
        "headers" => %{
          "0" => %{"key" => "X-H", "value" => "1", "enabled" => "true"}
        }
      }

      out = RequestParams.from_form(params, base)
      assert out.headers == [%{key: "X-H", value: "1", enabled: true}]
    end

    test "missing rows section falls back to base", %{base: base} do
      base = %{base | headers: [%{key: "X", value: "y", enabled: true}]}
      out = RequestParams.from_form(%{}, base)
      assert out.headers == [%{key: "X", value: "y", enabled: true}]
    end

    test "enabled defaults to false when only the hidden field is sent" do
      base = Request.new()

      params = %{
        "query_params" => %{
          "0" => %{"key" => "a", "value" => "1", "enabled" => "false"}
        }
      }

      out = RequestParams.from_form(params, base)
      assert hd(out.query_params).enabled == false
    end
  end

  describe "auth" do
    test "none type returns the canonical shape", %{base: base} do
      out = RequestParams.from_form(%{"auth" => %{"type" => "none"}}, base)
      assert out.auth == %{type: :none}
    end

    test "bearer keeps the token", %{base: base} do
      out = RequestParams.from_form(%{"auth" => %{"type" => "bearer", "token" => "abc"}}, base)
      assert out.auth == %{type: :bearer, token: "abc"}
    end

    test "api_key parses key/value/in", %{base: base} do
      out =
        RequestParams.from_form(
          %{
            "auth" => %{
              "type" => "api_key",
              "key" => "X-K",
              "value" => "v",
              "in" => "query"
            }
          },
          base
        )

      assert out.auth == %{type: :api_key, key: "X-K", value: "v", in: :query}
    end

    test "api_key location defaults to header when blank", %{base: base} do
      out = RequestParams.from_form(%{"auth" => %{"type" => "api_key"}}, base)
      assert out.auth == %{type: :api_key, key: "", value: "", in: :header}
    end

    test "missing auth section keeps base auth", %{base: base} do
      base = %{base | auth: %{type: :bearer, token: "keep"}}
      out = RequestParams.from_form(%{"url" => "https://q/"}, base)
      assert out.auth == %{type: :bearer, token: "keep"}
    end
  end
end
