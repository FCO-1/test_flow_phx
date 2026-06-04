defmodule TestFlowPhx.Smoke.Tabs do
  @moduledoc """
  Smoke test manual del flujo `UseCases.Tabs` tal como lo usa la LiveView:
  load on mount → mutate → save → restart → reload.

  Prerequisito: directorio `data/` existe y el `JsonFileRepo` está corriendo
  (lo está por defecto en `iex -S mix`).

  Ejecutar:

      iex -S mix
      TestFlowPhx.Smoke.Tabs.todos()

  ⚠️ Muta `data/state.json`. El último paso limpia las entradas.
  """

  alias TestFlowPhx.Domain.Rest.Request
  alias TestFlowPhx.Infrastructure.Storage.JsonFileRepo
  alias TestFlowPhx.UseCases.Tabs

  def todos do
    reset_checks()
    paso_1_estado_inicial()
    paso_2_save_dos_tabs()
    paso_3_cambiar_active()
    paso_4_restart_sobrevive()
    paso_5_cleanup()
    resumen_checks()
  end

  def paso_1_estado_inicial do
    IO.puts("\n=== PASO 1: snapshot del estado de tabs ===")
    initial = Tabs.list()
    IO.puts("   tabs actuales: #{length(initial)}")
    IO.puts("   active_id   : #{inspect(Tabs.active_id())}")
    record_check("Tabs.list/0 retorna lista", true, is_list(initial))
    :ok
  end

  def paso_2_save_dos_tabs do
    IO.puts("\n=== PASO 2: persistir dos tabs ===")

    tabs = [
      Request.new(id: "smoke-tab-a", method: "GET", url: "https://x/a"),
      Request.new(id: "smoke-tab-b", method: "POST", url: "https://x/b")
    ]

    :ok = Tabs.save(tabs, "smoke-tab-a")

    ids = Tabs.list() |> Enum.map(& &1.id)
    record_check("tabs persistidos en orden", ["smoke-tab-a", "smoke-tab-b"], ids)
    record_check("active_id == smoke-tab-a", "smoke-tab-a", Tabs.active_id())
    :ok
  end

  def paso_3_cambiar_active do
    IO.puts("\n=== PASO 3: cambiar tab activo ===")
    :ok = Tabs.save(Tabs.list(), "smoke-tab-b")
    record_check("active_id == smoke-tab-b", "smoke-tab-b", Tabs.active_id())
    :ok
  end

  def paso_4_restart_sobrevive do
    IO.puts("\n=== PASO 4: restart del GenServer — tabs sobreviven ===")

    pid = Process.whereis(JsonFileRepo)

    if pid do
      Process.exit(pid, :normal)
      wait_until_restart()
    end

    ids = Tabs.list() |> Enum.map(& &1.id)
    record_check("tabs sobreviven al restart", ["smoke-tab-a", "smoke-tab-b"], ids)
    record_check("active_id sobrevive al restart", "smoke-tab-b", Tabs.active_id())
    :ok
  end

  def paso_5_cleanup do
    IO.puts("\n=== PASO 5: cleanup ===")
    :ok = Tabs.save([], nil)
    record_check("tabs vacíos", [], Tabs.list())
    record_check("active_id == nil", nil, Tabs.active_id())
    Process.sleep(700)
    :ok
  end

  # ---------- Checks framework (mismo patrón que Smoke.Storage) ----------

  def reset_checks do
    Process.put(:smoke_checks, [])
    :ok
  end

  def resumen_checks do
    checks = Process.get(:smoke_checks, []) |> Enum.reverse()
    pass = Enum.count(checks, fn %{pass?: p} -> p end)
    fail = length(checks) - pass

    IO.puts("\n\n=== RESUMEN DE CHECKS ===")

    Enum.each(checks, fn %{label: label, expected: exp, actual: act, pass?: pass?} ->
      mark = if pass?, do: "[PASS]", else: "[FAIL]"
      IO.puts("#{mark} #{label}")

      unless pass? do
        IO.puts("       esperado : #{inspect(exp)}")
        IO.puts("       actual   : #{inspect(act)}")
      end
    end)

    IO.puts("\nTotal: #{pass} PASS / #{fail} FAIL (#{length(checks)} checks)")
    %{pass: pass, fail: fail, total: length(checks)}
  end

  defp record_check(label, expected, actual) do
    pass? = expected == actual
    entry = %{label: label, expected: expected, actual: actual, pass?: pass?}
    Process.put(:smoke_checks, [entry | Process.get(:smoke_checks, [])])

    mark = if pass?, do: "[PASS]", else: "[FAIL]"
    IO.puts("   #{mark} #{label}")

    unless pass? do
      IO.puts("          esperado : #{inspect(expected)}")
      IO.puts("          actual   : #{inspect(actual)}")
    end

    :ok
  end

  defp wait_until_restart(attempts \\ 50) do
    Enum.reduce_while(1..attempts, nil, fn _i, _acc ->
      case Process.whereis(JsonFileRepo) do
        pid when is_pid(pid) -> {:halt, pid}
        nil -> Process.sleep(50) && {:cont, nil}
      end
    end)
  end
end
