defmodule TestFlowPhx.Smoke.HttpExecutor do
  @moduledoc """
  Smoke test manual del flujo HTTP end-to-end.

  Ejercita el caso de uso `TestFlowPhx.UseCases.SendRequest` contra
  `https://httpbin.org/*` y verifica que el adapter actual (configurado
  en `config :test_flow_phx, :http_executor`) construye la petición
  correctamente y decodifica la respuesta.

  Prerequisito: red disponible hacia httpbin.org.

  Ejecutar desde iex:

      iex -S mix
      TestFlowPhx.Smoke.HttpExecutor.todos()

  O paso a paso:

      alias TestFlowPhx.Smoke.HttpExecutor, as: H
      H.reset_checks()
      H.paso_1_get_con_query()
      H.paso_2_post_json()
      H.paso_3_bearer_token()
      H.paso_4_api_key_header()
      H.paso_5_api_key_query()
      H.paso_6_url_invalida()
      H.paso_7_paths_helpers()
      H.resumen_checks()
  """

  alias TestFlowPhx.Domain.{Request, Response}
  alias TestFlowPhx.Infrastructure.Storage.Paths
  alias TestFlowPhx.UseCases.SendRequest

  @httpbin "https://httpbin.org"

  # ---------- Orquestador ----------

  def todos do
    reset_checks()
    paso_1_get_con_query()
    paso_2_post_json()
    paso_3_bearer_token()
    paso_4_api_key_header()
    paso_5_api_key_query()
    paso_6_url_invalida()
    paso_7_paths_helpers()
    resumen_checks()
  end

  # ---------- Pasos ----------

  def paso_1_get_con_query do
    IO.puts("\n=== PASO 1: GET con query param ===")

    req =
      Request.new(
        method: "GET",
        url: @httpbin <> "/get",
        query_params: [%{key: "foo", value: "bar", enabled: true}]
      )

    {resp, _} = SendRequest.execute(req, record_history?: false)
    render_response(resp)

    record_check("status == 200", 200, resp.status)
    record_check("body_decoded.args.foo == \"bar\"", "bar", get_in(resp.body_decoded, ["args", "foo"]))
    record_check("error == nil", nil, resp.error)

    resp
  end

  def paso_2_post_json do
    IO.puts("\n=== PASO 2: POST JSON ===")

    req =
      Request.new(
        method: "POST",
        url: @httpbin <> "/post",
        body_type: :json,
        body_text: ~s({"hello":"world","n":42})
      )

    {resp, _} = SendRequest.execute(req, record_history?: false)
    render_response(resp)

    record_check("status == 200", 200, resp.status)
    record_check("json.hello == \"world\"", "world", get_in(resp.body_decoded, ["json", "hello"]))
    record_check("json.n == 42", 42, get_in(resp.body_decoded, ["json", "n"]))

    record_check(
      "content-type enviado application/json",
      "application/json",
      get_in(resp.body_decoded, ["headers", "Content-Type"])
    )

    resp
  end

  def paso_3_bearer_token do
    IO.puts("\n=== PASO 3: Auth Bearer ===")
    token = "smoke-token-abc123"

    req =
      Request.new(
        method: "GET",
        url: @httpbin <> "/bearer",
        auth: %{type: :bearer, token: token}
      )

    {resp, _} = SendRequest.execute(req, record_history?: false)
    render_response(resp)

    record_check("status == 200", 200, resp.status)
    record_check("body_decoded.token == token", token, get_in(resp.body_decoded, ["token"]))
    record_check("authenticated", true, get_in(resp.body_decoded, ["authenticated"]))

    resp
  end

  def paso_4_api_key_header do
    IO.puts("\n=== PASO 4: Auth API Key en header ===")
    key = "X-Api-Key"
    value = "smoke-key-xyz"

    req =
      Request.new(
        method: "GET",
        url: @httpbin <> "/headers",
        auth: %{type: :api_key, key: key, value: value, in: :header}
      )

    {resp, _} = SendRequest.execute(req, record_history?: false)
    render_response(resp)

    record_check("status == 200", 200, resp.status)

    record_check(
      "headers.X-Api-Key == value",
      value,
      get_in(resp.body_decoded, ["headers", "X-Api-Key"])
    )

    resp
  end

  def paso_5_api_key_query do
    IO.puts("\n=== PASO 5: Auth API Key en query ===")
    key = "apikey"
    value = "smoke-query-key-789"

    req =
      Request.new(
        method: "GET",
        url: @httpbin <> "/get",
        auth: %{type: :api_key, key: key, value: value, in: :query}
      )

    {resp, _} = SendRequest.execute(req, record_history?: false)
    render_response(resp)

    record_check("status == 200", 200, resp.status)

    record_check(
      "args.apikey == value",
      value,
      get_in(resp.body_decoded, ["args", "apikey"])
    )

    resp
  end

  def paso_6_url_invalida do
    IO.puts("\n=== PASO 6: URL vacía debe devolver error sin red ===")

    req = Request.new(method: "GET", url: "")
    {resp, _} = SendRequest.execute(req, record_history?: false)
    render_response(resp)

    record_check("error.type == :invalid_request", :invalid_request, get_in(resp.error, [:type]))
    record_check("status == nil", nil, resp.status)

    resp
  end

  def paso_7_paths_helpers do
    IO.puts("\n=== PASO 7: helpers de Paths para resultados por ejecución ===")

    epoch = Paths.now_epoch_ms()
    today = Date.utc_today()
    file = Paths.result_file(:rest, today, epoch, Paths.extension_for("application/json"))

    IO.puts("   epoch_ms : #{epoch}")
    IO.puts("   today    : #{today}")
    IO.puts("   file     : #{file}")

    record_check("epoch_ms > 0", true, epoch > 0)

    record_check(
      "file path contiene /rest/#{today}/",
      true,
      String.contains?(file, "/rest/#{Date.to_iso8601(today)}/")
    )

    record_check("file termina en .json", true, String.ends_with?(file, ".json"))
    record_check("ext +json suffix → json", "json", Paths.extension_for("application/vnd.foo+json"))
    record_check("ext desconocida → bin", "bin", Paths.extension_for("totally/unknown"))

    :ok
  end

  # ---------- Checks framework ----------

  def reset_checks do
    Process.put(:smoke_checks, [])
    :ok
  end

  def resumen_checks do
    checks = Process.get(:smoke_checks, []) |> Enum.reverse()
    pass = Enum.count(checks, fn %{pass?: p} -> p end)
    fail = length(checks) - pass

    IO.puts("\n\n=== RESUMEN DE CHECKS ===")

    Enum.each(checks, fn %{label: label, expected: exp, actual: act, pass?: pass?, detail: detail} ->
      mark = if pass?, do: "[PASS]", else: "[FAIL]"
      IO.puts("#{mark} #{label}")

      unless pass? do
        IO.puts("       esperado : #{inspect(exp)}")
        IO.puts("       actual   : #{inspect(act)}")
        if detail, do: IO.puts("       detalle  : #{detail}")
      end
    end)

    IO.puts("\nTotal: #{pass} PASS / #{fail} FAIL (#{length(checks)} checks)")

    %{pass: pass, fail: fail, total: length(checks)}
  end

  # ---------- Helpers privados ----------

  defp record_check(label, expected, actual, detail \\ nil) do
    pass? = values_match?(expected, actual)
    entry = %{label: label, expected: expected, actual: actual, pass?: pass?, detail: detail}
    Process.put(:smoke_checks, [entry | Process.get(:smoke_checks, [])])

    mark = if pass?, do: "[PASS]", else: "[FAIL]"
    IO.puts("   #{mark} #{label}")

    unless pass? do
      IO.puts("          esperado : #{inspect(expected)}")
      IO.puts("          actual   : #{inspect(actual)}")
      if detail, do: IO.puts("          detalle  : #{detail}")
    end

    :ok
  end

  defp values_match?(a, b), do: a == b

  defp render_response(%Response{error: nil} = r) do
    IO.puts("   status   : #{r.status}")
    IO.puts("   duration : #{r.duration_ms} ms")
    IO.puts("   size     : #{r.size_bytes} bytes")

    if r.body_decoded do
      IO.inspect(r.body_decoded, pretty: true, label: "   body_decoded", limit: 5)
    end
  end

  defp render_response(%Response{error: error} = r) do
    IO.puts("   ERROR")
    IO.puts("   duration : #{r.duration_ms} ms")
    IO.inspect(error, pretty: true, label: "   error")
  end
end
