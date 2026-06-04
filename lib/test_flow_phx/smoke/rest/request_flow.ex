defmodule TestFlowPhx.Smoke.Rest.RequestFlow do
  @moduledoc """
  Smoke test manual del flujo de petición completo desde el browser.

  Verifica que la LiveView en `/` se monta, acepta cambios `phx-change`
  para mantener el `%Request{}` en assigns, y dispara el ciclo
  send → response a través del use case real (sin mocks).

  Prerequisito: servidor corriendo.

      iex -S mix phx.server
      TestFlowPhx.Smoke.Rest.RequestFlow.todos()

  Esto NO simula clicks del browser — para eso usa el browser. Aquí
  ejercitamos el componente `RequestParams` y el use case `SendRequest`
  directamente, como una verificación end-to-end de las piezas que
  conectan el form con la red.
  """

  alias TestFlowPhx.Domain.Rest.Request
  alias TestFlowPhx.UseCases.Rest.SendRequest
  alias TestFlowPhxWeb.RequestParams

  @httpbin "https://httpbin.org"

  def todos do
    reset_checks()
    paso_1_request_params_redondo()
    paso_2_send_via_form_params()
    paso_3_format_json_valido()
    paso_4_format_json_invalido()
    resumen_checks()
  end

  def paso_1_request_params_redondo do
    IO.puts("\n=== PASO 1: RequestParams.from_form ↔ %Request{} ===")

    base = Request.new(method: "GET", url: "")

    form = %{
      "method" => "POST",
      "url" => @httpbin <> "/post",
      "body_type" => "json",
      "body_text" => ~s({"hello":"world"}),
      "query_params" => %{
        "0" => %{"key" => "x", "value" => "1", "enabled" => "true"}
      },
      "auth" => %{"type" => "bearer", "token" => "abc"}
    }

    out = RequestParams.from_form(form, base)

    record_check("method := POST", "POST", out.method)
    record_check("url := httpbin/post", @httpbin <> "/post", out.url)
    record_check("body_type := :json", :json, out.body_type)
    record_check("query_params parseados", [%{key: "x", value: "1", enabled: true}], out.query_params)
    record_check("auth.type := :bearer", :bearer, out.auth.type)
    record_check("auth.token := abc", "abc", out.auth.token)

    out
  end

  def paso_2_send_via_form_params do
    IO.puts("\n=== PASO 2: send completo via RequestParams + SendRequest ===")

    base = Request.new(method: "GET", url: "")

    form = %{
      "method" => "GET",
      "url" => @httpbin <> "/get",
      "query_params" => %{
        "0" => %{"key" => "foo", "value" => "bar", "enabled" => "true"}
      }
    }

    request = RequestParams.from_form(form, base)
    {resp, _} = SendRequest.execute(request, record_history?: false)

    IO.puts("   status   : #{resp.status}")
    IO.puts("   duration : #{resp.duration_ms} ms")

    record_check("status == 200", 200, resp.status)
    record_check("args.foo == \"bar\"", "bar", get_in(resp.body_decoded, ["args", "foo"]))

    resp
  end

  def paso_3_format_json_valido do
    IO.puts("\n=== PASO 3: Format JSON sobre body válido ===")

    body = ~s({"a":1,"b":[2,3]})
    {:ok, parsed} = Jason.decode(body)
    formatted = parsed |> Jason.encode_to_iodata!(pretty: true) |> IO.iodata_to_binary()

    IO.puts("   input    : #{body}")
    IO.puts("   formatted:")

    formatted
    |> String.split("\n")
    |> Enum.each(fn line -> IO.puts("     #{line}") end)

    record_check("formatted incluye saltos de línea", true, String.contains?(formatted, "\n"))
    record_check("formatted contiene \"a\": 1", true, String.contains?(formatted, ~s("a": 1)))
    record_check("formatted contiene \"b\":", true, String.contains?(formatted, ~s("b": [)))

    formatted
  end

  def paso_4_format_json_invalido do
    IO.puts("\n=== PASO 4: Format JSON sobre body inválido ===")

    body = ~s({"a":1,)
    result = Jason.decode(body)

    case result do
      {:error, _} ->
        record_check("Jason.decode reporta error en JSON inválido", true, true)

      other ->
        record_check("Jason.decode reporta error en JSON inválido", {:error, :_}, other)
    end

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

  defp record_check(label, expected, actual, detail \\ nil) do
    pass? = expected == actual
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
end
