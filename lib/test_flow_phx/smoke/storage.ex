defmodule TestFlowPhx.Smoke.Storage do
  @moduledoc """
  Smoke test manual del adapter `JsonFileRepo`.

  Ejercita el ciclo completo: crea colecciones y entradas de historial,
  comprueba que se mantienen en memoria, espera el flush a disco
  (debounce 500 ms en dev), reinicia el GenServer y verifica que los
  datos sobreviven.

  Prerequisito: directorio `data/` (creado por `.gitkeep`).

  Ejecutar desde iex:

      iex -S mix
      TestFlowPhx.Smoke.Storage.todos()

  O paso a paso:

      alias TestFlowPhx.Smoke.Storage, as: S
      S.reset_checks()
      S.paso_1_estado_inicial()
      S.paso_2_crear_coleccion()
      S.paso_3_agregar_request()
      S.paso_4_append_history()
      S.paso_5_set_tabs()
      S.paso_6_flush_a_disco()
      S.paso_7_restart_sobrevive()
      S.paso_8_cleanup()
      S.resumen_checks()

  ⚠️ Este smoke MUTA `data/state.json`. El último paso (`paso_8_cleanup`)
  borra las entradas creadas para dejar el archivo limpio.
  """

  alias TestFlowPhx.Domain.{Collection, HistoryEntry, Request}
  alias TestFlowPhx.Infrastructure.Storage.{JsonFileRepo, Paths}
  alias TestFlowPhx.UseCases.{Collections, History, Tabs}

  @smoke_collection_id "smoke-collection-id"
  @smoke_request_id "smoke-request-id"
  @smoke_history_id "smoke-history-id"

  def todos do
    reset_checks()
    paso_1_estado_inicial()
    paso_2_crear_coleccion()
    paso_3_agregar_request()
    paso_4_append_history()
    paso_5_set_tabs()
    paso_6_flush_a_disco()
    paso_7_restart_sobrevive()
    paso_8_cleanup()
    resumen_checks()
  end

  # ---------- Pasos ----------

  def paso_1_estado_inicial do
    IO.puts("\n=== PASO 1: estado inicial del repo ===")
    state_file = Paths.state_file()
    IO.puts("   state_file : #{state_file}")
    IO.puts("   exists?    : #{File.exists?(state_file)}")
    IO.puts("   collections: #{length(Collections.list())}")
    IO.puts("   history    : #{length(History.list(100))}")
    IO.puts("   tabs       : #{length(Tabs.list())}")

    record_check("Collections.list/0 retorna lista", true, is_list(Collections.list()))
    :ok
  end

  def paso_2_crear_coleccion do
    IO.puts("\n=== PASO 2: upsert colección con id determinístico ===")

    coll = %Collection{id: @smoke_collection_id, name: "Smoke Storage", requests: []}
    :ok = JsonFileRepo.upsert_collection(coll)

    found = Enum.find(Collections.list(), &(&1.id == @smoke_collection_id))
    record_check("colección recuperada por id", @smoke_collection_id, found && found.id)
    record_check("nombre persistido", "Smoke Storage", found && found.name)

    :ok
  end

  def paso_3_agregar_request do
    IO.puts("\n=== PASO 3: agregar request a la colección ===")

    req =
      Request.new(
        id: @smoke_request_id,
        name: "Ping smoke",
        method: "GET",
        url: "https://httpbin.org/get"
      )

    Collections.add_request(@smoke_collection_id, req)

    coll = Enum.find(Collections.list(), &(&1.id == @smoke_collection_id))
    ids = coll && Enum.map(coll.requests, & &1.id)
    record_check("request agregada a colección", true, ids && @smoke_request_id in ids)

    :ok
  end

  def paso_4_append_history do
    IO.puts("\n=== PASO 4: append history ===")

    entry = %HistoryEntry{
      id: @smoke_history_id,
      ran_at: DateTime.utc_now(),
      request: Request.new(id: "req-x", method: "GET", url: "https://httpbin.org/get"),
      response_status: 200,
      response_duration_ms: 42,
      response_size_bytes: 100,
      response_error: nil,
      result_file: "data/rest/2026-05-15/smoke.json"
    }

    History.append(entry)

    [latest | _] = History.list(5)
    record_check("history newest first", @smoke_history_id, latest.id)
    record_check("ran_at es DateTime", true, is_struct(latest.ran_at, DateTime))
    record_check("result_file preservado", "data/rest/2026-05-15/smoke.json", latest.result_file)

    :ok
  end

  def paso_5_set_tabs do
    IO.puts("\n=== PASO 5: set tabs ===")

    tabs = [
      Request.new(id: "tab-a", method: "GET", url: "https://x/a"),
      Request.new(id: "tab-b", method: "POST", url: "https://x/b")
    ]

    Tabs.save(tabs, "tab-b")

    record_check("tabs guardados", ["tab-a", "tab-b"], Tabs.list() |> Enum.map(& &1.id))
    record_check("active_tab_id == tab-b", "tab-b", Tabs.active_id())

    :ok
  end

  def paso_6_flush_a_disco do
    IO.puts("\n=== PASO 6: flush a disco (espera de debounce + verifica archivo) ===")

    state_file = Paths.state_file()
    deadline_ms = 1_500
    started = System.monotonic_time(:millisecond)

    loop = fn loop ->
      cond do
        File.exists?(state_file) ->
          :ok

        System.monotonic_time(:millisecond) - started > deadline_ms ->
          :timeout

        true ->
          Process.sleep(50)
          loop.(loop)
      end
    end

    result = loop.(loop)
    record_check("archivo state.json existe", :ok, result)

    if result == :ok do
      decoded = state_file |> File.read!() |> Jason.decode!()
      colls = decoded["collections"] || []
      coll_ids = Enum.map(colls, & &1["id"])

      record_check(
        "colección persistida en JSON",
        true,
        @smoke_collection_id in coll_ids
      )

      record_check(
        "version del documento = 1",
        1,
        decoded["version"]
      )
    end

    :ok
  end

  def paso_7_restart_sobrevive do
    IO.puts("\n=== PASO 7: restart del GenServer — datos sobreviven ===")

    pid = Process.whereis(JsonFileRepo)

    if pid do
      Process.exit(pid, :normal)
      wait_until_restart()
    end

    coll = Enum.find(Collections.list(), &(&1.id == @smoke_collection_id))
    record_check("colección sobrevive al restart", @smoke_collection_id, coll && coll.id)

    history_ids = History.list(10) |> Enum.map(& &1.id)
    record_check("history sobrevive al restart", true, @smoke_history_id in history_ids)

    :ok
  end

  def paso_8_cleanup do
    IO.puts("\n=== PASO 8: cleanup — borrar entradas smoke del state.json ===")

    Collections.delete(@smoke_collection_id)
    History.clear()
    Tabs.save([], nil)

    record_check(
      "colección eliminada",
      nil,
      Enum.find(Collections.list(), &(&1.id == @smoke_collection_id))
    )

    record_check("history vacío", [], History.list(10))
    record_check("tabs vacíos", [], Tabs.list())

    Process.sleep(700)
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

  # ---------- Helpers ----------

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

  defp wait_until_restart(attempts \\ 50) do
    Enum.reduce_while(1..attempts, nil, fn _i, _acc ->
      case Process.whereis(JsonFileRepo) do
        pid when is_pid(pid) -> {:halt, pid}
        nil -> Process.sleep(50) && {:cont, nil}
      end
    end)
  end
end
