defmodule TestFlowPhx.UseCases.GlobalsTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Infrastructure.Storage.JsonFileRepo
  alias TestFlowPhx.UseCases.Globals

  setup do
    tmp = Path.join(System.tmp_dir!(), "test_flow_globals_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    path = Path.join(tmp, "state.json")

    start_supervised!(
      {JsonFileRepo, name: JsonFileRepo, path: path, flush_after_ms: 10}
    )

    :ok
  end

  test "list/0 devuelve [] cuando no se ha guardado nada" do
    assert Globals.list() == []
  end

  test "replace/1 persiste la lista y list/0 la recupera" do
    vars = [
      %{name: "base_url", value: "https://api", enabled: true},
      %{name: "token", value: "secret", enabled: false}
    ]

    assert :ok = Globals.replace(vars)
    assert Globals.list() == vars
  end

  test "replace/1 reemplaza completo (no merge)" do
    Globals.replace([%{name: "a", value: "1", enabled: true}])
    Globals.replace([%{name: "b", value: "2", enabled: true}])

    assert Globals.list() == [%{name: "b", value: "2", enabled: true}]
  end

end
