defmodule TestFlowPhx.UseCases.CurlExportTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Domain.Request
  alias TestFlowPhx.UseCases.CurlExport

  defp req(attrs), do: Request.new(attrs)
  defp kv(k, v, enabled \\ true), do: %{key: k, value: v, enabled: enabled}

  defp form_text(k, v, enabled \\ true),
    do: %{key: k, value: v, enabled: enabled, type: :text, file_path: nil}

  defp form_file(k, path, enabled \\ true),
    do: %{key: k, value: "", enabled: enabled, type: :file, file_path: path}

  test "minimal GET" do
    out = CurlExport.from_request(req(%{method: "GET", url: "https://api.test/items"}))
    assert out == "curl \\\n  -X GET \\\n  'https://api.test/items'"
  end

  test "appends enabled query params and ignores disabled ones" do
    out =
      CurlExport.from_request(
        req(%{
          method: "GET",
          url: "https://api.test/items",
          query_params: [kv("a", "1"), kv("b", "2", false), kv("c", "3")]
        })
      )

    assert out =~ "'https://api.test/items?a=1&c=3'"
  end

  test "merges into existing query string with & separator" do
    out =
      CurlExport.from_request(
        req(%{url: "https://api.test/items?x=0", query_params: [kv("a", "1")]})
      )

    assert out =~ "'https://api.test/items?x=0&a=1'"
  end

  test "renders enabled headers, drops disabled and empty keys" do
    out =
      CurlExport.from_request(
        req(%{
          url: "https://x",
          headers: [kv("X-A", "1"), kv("X-B", "2", false), kv("", "skip")]
        })
      )

    assert out =~ "-H 'X-A: 1'"
    refute out =~ "X-B"
    refute out =~ "': skip'"
  end

  test "bearer auth adds Authorization header" do
    out =
      CurlExport.from_request(
        req(%{url: "https://x", auth: %{type: :bearer, token: "abc"}})
      )

    assert out =~ "-H 'Authorization: Bearer abc'"
  end

  test "api_key in header" do
    out =
      CurlExport.from_request(
        req(%{
          url: "https://x",
          auth: %{type: :api_key, key: "X-Api-Key", value: "k1", in: :header}
        })
      )

    assert out =~ "-H 'X-Api-Key: k1'"
  end

  test "api_key in query is merged into URL, not headers" do
    out =
      CurlExport.from_request(
        req(%{
          url: "https://x",
          auth: %{type: :api_key, key: "api_key", value: "k1", in: :query}
        })
      )

    assert out =~ "'https://x?api_key=k1'"
    refute out =~ "-H 'api_key"
  end

  test "user header takes precedence over auth header (no duplicate Authorization)" do
    out =
      CurlExport.from_request(
        req(%{
          url: "https://x",
          headers: [kv("authorization", "Bearer override")],
          auth: %{type: :bearer, token: "ignored"}
        })
      )

    assert out =~ "-H 'authorization: Bearer override'"
    refute out =~ "Bearer ignored"
  end

  test "json body uses --data and adds Content-Type" do
    out =
      CurlExport.from_request(
        req(%{
          method: "POST",
          url: "https://x",
          body_type: :json,
          body_text: ~s({"a":1})
        })
      )

    assert out =~ "-H 'Content-Type: application/json'"
    assert out =~ "--data '{\"a\":1}'"
  end

  test "empty json body emits no --data and no Content-Type" do
    out =
      CurlExport.from_request(
        req(%{method: "POST", url: "https://x", body_type: :json, body_text: ""})
      )

    refute out =~ "--data"
    refute out =~ "Content-Type"
  end

  test "raw body uses --data-raw without Content-Type" do
    out =
      CurlExport.from_request(
        req(%{
          method: "POST",
          url: "https://x",
          body_type: :raw,
          body_text: "hello world"
        })
      )

    assert out =~ "--data-raw 'hello world'"
    refute out =~ "Content-Type"
  end

  test "form_urlencoded emits one --data-urlencode per enabled text row" do
    out =
      CurlExport.from_request(
        req(%{
          method: "POST",
          url: "https://x",
          body_type: :form_urlencoded,
          body_form: [
            form_text("a", "1"),
            form_text("b", "2", false),
            form_text("", "skip"),
            form_text("c", "3")
          ]
        })
      )

    assert out =~ "-H 'Content-Type: application/x-www-form-urlencoded'"
    assert out =~ "--data-urlencode 'a=1'"
    assert out =~ "--data-urlencode 'c=3'"
    refute out =~ "b=2"
  end

  test "multipart emits -F for text and -F @path for files" do
    out =
      CurlExport.from_request(
        req(%{
          method: "POST",
          url: "https://x",
          body_type: :multipart,
          body_form: [
            form_text("name", "alice"),
            form_file("avatar", "/tmp/a.png"),
            form_file("skip", "", true),
            form_text("disabled", "x", false)
          ]
        })
      )

    assert out =~ "-F 'name=alice'"
    assert out =~ "-F 'avatar=@/tmp/a.png'"
    refute out =~ "skip="
    refute out =~ "disabled="
  end

  test "shell-escapes single quotes in values" do
    out =
      CurlExport.from_request(
        req(%{
          method: "POST",
          url: "https://x",
          body_type: :raw,
          body_text: "it's fine"
        })
      )

    assert out =~ ~S{--data-raw 'it'\''s fine'}
  end

  describe "variables (Fase M)" do
    test "resuelve {{vars}} en URL, headers, body y auth antes de imprimir" do
      r =
        req(%{
          method: "POST",
          url: "{{base_url}}/users",
          headers: [%{key: "X-Trace", value: "{{trace}}", enabled: true}],
          body_type: :json,
          body_text: ~s({"id":"{{user_id}}"}),
          auth: %{type: :bearer, token: "{{token}}"}
        })

      vars = %{
        "base_url" => "https://api",
        "trace" => "abc",
        "user_id" => "u-7",
        "token" => "secret"
      }

      out = CurlExport.from_request(r, vars)

      assert out =~ "'https://api/users'"
      assert out =~ "-H 'X-Trace: abc'"
      assert out =~ ~s(--data '{"id":"u-7"}')
      assert out =~ "-H 'Authorization: Bearer secret'"
      refute out =~ "{{"
    end

    test "sin vars el comando lleva los placeholders literales" do
      r = req(%{method: "GET", url: "{{base_url}}/x"})
      assert CurlExport.from_request(r) =~ "{{base_url}}/x"
    end
  end
end
