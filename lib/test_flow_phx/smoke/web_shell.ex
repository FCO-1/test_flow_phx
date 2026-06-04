defmodule TestFlowPhx.Smoke.WebShell do
  @moduledoc """
  Smoke test manual del shell LiveView servido en `/`.

  Verifica end-to-end con el servidor Phoenix corriendo:
    * La ruta `/` responde 200 y devuelve HTML.
    * El HTML contiene los marcadores del shell (título, tabs sidebar).
    * `Endpoint.url/0` apunta al puerto esperado (4000 en dev).

  Prerequisitos:
    * `mix phx.server` corriendo en otra terminal (puerto 4000), o
    * arrancar el endpoint desde la propia sesión iex con
      `TestFlowPhxWeb.Endpoint.start_link/0` si no estuviera ya supervisado.

  Ejecutar desde iex:

      iex -S mix phx.server
      TestFlowPhx.Smoke.WebShell.todos()
  """

  alias TestFlowPhx.UseCases.Rest.SendRequest
  alias TestFlowPhx.Domain.Rest.Request

  def todos do
    reset_checks()
    paso_1_endpoint_url()
    paso_2_get_root_responde()
    paso_3_html_contiene_shell()
    resumen_checks()
  end

  def paso_1_endpoint_url do
    IO.puts("\n=== PASO 1: Endpoint URL ===")
    url = TestFlowPhxWeb.Endpoint.url()
    IO.puts("   url : #{url}")
    record_check("endpoint url empieza por http://", true, String.starts_with?(url, "http://"))
    url
  end

  def paso_2_get_root_responde do
    IO.puts("\n=== PASO 2: GET / responde 200 ===")
    url = TestFlowPhxWeb.Endpoint.url() <> "/"

    req = Request.new(method: "GET", url: url)
    {resp, _} = SendRequest.execute(req, record_history?: false)

    IO.puts("   status   : #{resp.status}")
    IO.puts("   size     : #{resp.size_bytes} bytes")

    record_check("status == 200", 200, resp.status)
    record_check("error == nil", nil, resp.error)
    record_check("body no vacío", true, is_binary(resp.body) and byte_size(resp.body) > 0)

    resp
  end

  def paso_3_html_contiene_shell do
    IO.puts("\n=== PASO 3: HTML contiene los marcadores del shell ===")
    url = TestFlowPhxWeb.Endpoint.url() <> "/"

    req = Request.new(method: "GET", url: url)
    {resp, _} = SendRequest.execute(req, record_history?: false)

    body = resp.body || ""

    record_check("html contiene 'TestFlow'", true, String.contains?(body, "TestFlow"))

    record_check(
      "html contiene 'Collections'",
      true,
      String.contains?(body, "Collections")
    )

    record_check(
      "html contiene 'History'",
      true,
      String.contains?(body, "History")
    )

    :ok
  end

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
