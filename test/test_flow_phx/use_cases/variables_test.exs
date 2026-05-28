defmodule TestFlowPhx.UseCases.VariablesTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Domain.Request
  alias TestFlowPhx.UseCases.Variables

  describe "merge/2" do
    test "combina globales y colección con llaves name → value" do
      globals = [
        %{name: "base_url", value: "https://api.global", enabled: true},
        %{name: "token", value: "global-token", enabled: true}
      ]

      coll = [%{name: "extra", value: "X", enabled: true}]

      assert Variables.merge(globals, coll) == %{
               "base_url" => "https://api.global",
               "token" => "global-token",
               "extra" => "X"
             }
    end

    test "colección gana sobre global con mismo name" do
      globals = [%{name: "base_url", value: "https://api.global", enabled: true}]
      coll = [%{name: "base_url", value: "https://api.coll", enabled: true}]

      assert Variables.merge(globals, coll) == %{"base_url" => "https://api.coll"}
    end

    test "descarta filas con enabled: false" do
      globals = [
        %{name: "live", value: "ok", enabled: true},
        %{name: "muted", value: "no", enabled: false}
      ]

      assert Variables.merge(globals, []) == %{"live" => "ok"}
    end

    test "descarta filas con name vacío o solo espacios" do
      globals = [
        %{name: "", value: "x", enabled: true},
        %{name: "   ", value: "y", enabled: true},
        %{name: "ok", value: "z", enabled: true}
      ]

      assert Variables.merge(globals, []) == %{"ok" => "z"}
    end
  end

  describe "resolve/2" do
    test "sustituye una variable simple" do
      assert Variables.resolve("{{base_url}}/users", %{"base_url" => "https://api"}) ==
               "https://api/users"
    end

    test "sustituye múltiples variables en el mismo string" do
      vars = %{"host" => "api.test", "id" => "42"}
      assert Variables.resolve("https://{{host}}/users/{{id}}", vars) == "https://api.test/users/42"
    end

    test "deja literal el placeholder cuando la var no existe" do
      assert Variables.resolve("{{base_url}}/users/{{missing}}", %{"base_url" => "https://api"}) ==
               "https://api/users/{{missing}}"
    end

    test "no toca strings sin placeholders" do
      assert Variables.resolve("https://api/users", %{}) == "https://api/users"
    end

    test "ignora placeholders mal formados" do
      assert Variables.resolve("{ {var}}", %{"var" => "X"}) == "{ {var}}"
      assert Variables.resolve("{{var space}}", %{"var space" => "X"}) == "{{var space}}"
    end

    test "passthrough en input no-string" do
      assert Variables.resolve(nil, %{}) == nil
      assert Variables.resolve(42, %{}) == 42
    end
  end

  describe "resolve_request/2" do
    test "resuelve URL, query, headers, body_text y auth" do
      req = %Request{
        method: "POST",
        url: "{{base_url}}/users",
        query_params: [%{key: "lang", value: "{{lang}}", enabled: true}],
        headers: [%{key: "X-Trace", value: "{{trace}}", enabled: true}],
        body_type: :json,
        body_text: ~s({"id":"{{user_id}}"}),
        body_form: [],
        auth: %{type: :bearer, token: "{{token}}"}
      }

      vars = %{
        "base_url" => "https://api",
        "lang" => "es",
        "trace" => "abc123",
        "user_id" => "u-7",
        "token" => "secret"
      }

      resolved = Variables.resolve_request(req, vars)

      assert resolved.url == "https://api/users"
      assert resolved.query_params == [%{key: "lang", value: "es", enabled: true}]
      assert resolved.headers == [%{key: "X-Trace", value: "abc123", enabled: true}]
      assert resolved.body_text == ~s({"id":"u-7"})
      assert resolved.auth == %{type: :bearer, token: "secret"}
    end

    test "resuelve auth api_key tanto en key como en value" do
      req = %Request{
        url: "https://api",
        auth: %{type: :api_key, key: "{{key_name}}", value: "{{key_value}}", in: :header}
      }

      vars = %{"key_name" => "X-Api-Key", "key_value" => "abc"}

      resolved = Variables.resolve_request(req, vars)

      assert resolved.auth == %{
               type: :api_key,
               key: "X-Api-Key",
               value: "abc",
               in: :header
             }
    end

    test "resuelve form rows pero NO toca file_path" do
      req = %Request{
        url: "https://api/upload",
        body_type: :multipart,
        body_form: [
          %{key: "user", value: "{{user_id}}", enabled: true, type: :text, file_path: nil},
          %{
            key: "doc",
            value: "{{label}}",
            enabled: true,
            type: :file,
            file_path: "/tmp/{{not_resolved}}.pdf"
          }
        ]
      }

      vars = %{"user_id" => "u-7", "label" => "annual report"}

      resolved = Variables.resolve_request(req, vars)

      assert resolved.body_form == [
               %{key: "user", value: "u-7", enabled: true, type: :text, file_path: nil},
               %{
                 key: "doc",
                 value: "annual report",
                 enabled: true,
                 type: :file,
                 file_path: "/tmp/{{not_resolved}}.pdf"
               }
             ]
    end

    test "request sin auth y sin body queda intacto fuera de URL" do
      req = %Request{url: "{{base}}/ping"}
      resolved = Variables.resolve_request(req, %{"base" => "https://api"})

      assert resolved.url == "https://api/ping"
      assert resolved.auth == %{type: :none}
    end
  end

  describe "empty/0" do
    test "devuelve fila vacía habilitada" do
      assert Variables.empty() == %{name: "", value: "", enabled: true}
    end
  end
end
