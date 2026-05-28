defmodule TestFlowPhx.UseCases.CollectionsTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.{Collection, Request}
  alias TestFlowPhx.Infrastructure.Storage.JsonFileRepo
  alias TestFlowPhx.UseCases.Collections

  setup do
    tmp = Path.join(System.tmp_dir!(), "test_flow_uc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    start_supervised!(
      {JsonFileRepo, name: JsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 10}
    )

    :ok
  end

  test "create assigns an id and persists" do
    coll = Collections.create("Smoke")

    assert %Collection{} = coll
    assert is_binary(coll.id) and coll.id != ""
    assert coll.name == "Smoke"
    assert [%Collection{id: id}] = Collections.list()
    assert id == coll.id
  end

  test "rename updates the name; returns :not_found for unknown id" do
    coll = Collections.create("Old")
    assert :ok = Collections.rename(coll.id, "New")
    assert [%Collection{name: "New"}] = Collections.list()

    assert {:error, :not_found} = Collections.rename("nope", "X")
  end

  test "delete removes it" do
    coll = Collections.create("X")
    assert :ok = Collections.delete(coll.id)
    assert Collections.list() == []
  end

  test "clear removes every collection in one call" do
    Collections.create("A")
    Collections.create("B")
    Collections.create("C")
    assert length(Collections.list()) == 3

    assert :ok = Collections.clear()
    assert Collections.list() == []
  end

  test "add_request and remove_request maintain the requests list" do
    coll = Collections.create("Box")

    req =
      Collections.add_request(
        coll.id,
        Request.new(method: "GET", url: "https://x.test/1")
      )

    assert is_binary(req.id) and req.id != ""

    [stored] = Collections.list()
    assert Enum.map(stored.requests, & &1.id) == [req.id]

    assert :ok = Collections.remove_request(coll.id, req.id)
    [stored] = Collections.list()
    assert stored.requests == []
  end

  test "set_variables reemplaza la lista de vars; :not_found si id desconocido" do
    coll = Collections.create("With Vars")

    vars = [
      %{name: "base_url", value: "https://api", enabled: true},
      %{name: "off", value: "x", enabled: false}
    ]

    assert :ok = Collections.set_variables(coll.id, vars)
    [stored] = Collections.list()
    assert stored.variables == vars

    # Reemplaza, no merge
    assert :ok = Collections.set_variables(coll.id, [%{name: "k", value: "v", enabled: true}])
    [stored] = Collections.list()
    assert stored.variables == [%{name: "k", value: "v", enabled: true}]

    assert {:error, :not_found} = Collections.set_variables("nope", [])
  end
end
