defmodule TestFlowPhx.UseCases.CollectionExportImportTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.{Collection, Request}
  alias TestFlowPhx.Infrastructure.Storage.JsonFileRepo
  alias TestFlowPhx.UseCases.{CollectionExport, CollectionImport, Collections}

  setup do
    tmp = Path.join(System.tmp_dir!(), "tf_exim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    start_supervised!(
      {JsonFileRepo, name: JsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 5}
    )

    :ok
  end

  defp seeded_collection(name) do
    c = Collections.create(name)
    Collections.add_request(c.id, Request.new(method: "GET", url: "https://api/#{name}/1"))
    Collections.add_request(c.id, Request.new(method: "POST", url: "https://api/#{name}/2"))
    Collections.list() |> Enum.find(&(&1.id == c.id))
  end

  describe "CollectionExport.build/1" do
    test "single collection envelope" do
      c = seeded_collection("Smoke")
      env = CollectionExport.build(c)

      assert env["format"] == "testflow-collection"
      assert env["version"] == 2
      assert is_binary(env["exported_at"])
      assert [%{"name" => "Smoke", "requests" => reqs, "variables" => []}] = env["collections"]
      assert length(reqs) == 2

      # IDs y collection_id stripped del export para que import no colisione.
      assert Enum.all?(reqs, fn r -> not Map.has_key?(r, "id") end)
      assert Enum.all?(reqs, fn r -> not Map.has_key?(r, "collection_id") end)
    end

    test "multiple collections envelope" do
      a = seeded_collection("A")
      b = seeded_collection("B")
      env = CollectionExport.build([a, b])

      names = Enum.map(env["collections"], & &1["name"])
      assert names == ["A", "B"]
    end

    test "to_json/1 produces valid JSON" do
      c = seeded_collection("J")
      json = CollectionExport.to_json(c)
      assert {:ok, %{"format" => "testflow-collection"}} = Jason.decode(json)
    end
  end

  describe "CollectionImport.parse/1" do
    test "parses a self-produced export back" do
      c = seeded_collection("Round Trip")
      json = CollectionExport.to_json(c)

      assert {:ok, [imported]} = CollectionImport.parse(json)
      assert %Collection{name: "Round Trip", requests: [_, _]} = imported

      # Fresh IDs were assigned (not just nil).
      assert is_binary(imported.id) and imported.id != c.id
      assert Enum.all?(imported.requests, &(is_binary(&1.id) and &1.id != ""))
    end

    test "rejects invalid JSON" do
      assert {:error, :invalid_json} = CollectionImport.parse("not json")
    end

    test "rejects unknown format" do
      assert {:error, :unknown_format} =
               CollectionImport.parse(~s({"format":"postman","version":1}))
    end

    test "rejects unsupported version" do
      assert {:error, :unsupported_version} =
               CollectionImport.parse(
                 ~s({"format":"testflow-collection","version":99,"collections":[]})
               )
    end

    test "rejects malformed envelopes (missing collections list)" do
      assert {:error, :malformed} =
               CollectionImport.parse(~s({"format":"testflow-collection","version":1}))
    end
  end

  describe "CollectionImport.import_all/1" do
    test "persists each collection and returns the count" do
      a = seeded_collection("Alpha")
      b = seeded_collection("Beta")
      json = CollectionExport.to_json([a, b])

      Collections.clear()
      assert Collections.list() == []

      assert {:ok, 2} = CollectionImport.import_all(json)
      assert length(Collections.list()) == 2

      names = Collections.list() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["Alpha", "Beta"]
    end

    test "importing the same file twice appends — never overwrites" do
      c = seeded_collection("Dup")
      json = CollectionExport.to_json(c)

      assert {:ok, 1} = CollectionImport.import_all(json)
      assert {:ok, 1} = CollectionImport.import_all(json)
      # Originally seeded "Dup" + two imports = 3 collections named "Dup".
      assert Collections.list() |> Enum.count(&(&1.name == "Dup")) == 3
    end
  end

  describe "variables en export/import (Fase M.6)" do
    test "v2 export incluye variables y round-trip las preserva" do
      c = Collections.create("With Vars")

      :ok =
        Collections.set_variables(c.id, [
          %{name: "host", value: "api.test", enabled: true},
          %{name: "off", value: "x", enabled: false}
        ])

      [stored] = Collections.list() |> Enum.filter(&(&1.id == c.id))
      json = CollectionExport.to_json(stored)

      assert {:ok, [imported]} = CollectionImport.parse(json)

      assert imported.variables == [
               %{name: "host", value: "api.test", enabled: true},
               %{name: "off", value: "x", enabled: false}
             ]
    end

    test "import de archivo v1 (sin campo variables) carga con vars vacías" do
      legacy_json = ~s({
        "format": "testflow-collection",
        "version": 1,
        "exported_at": "2026-05-17T00:00:00Z",
        "collections": [
          {
            "name": "Legacy",
            "requests": [
              {"method":"GET","url":"https://api/x","name":"r","query_params":[],"headers":[],"body_type":"none","body_text":"","body_form":[],"auth":{"type":"none"}}
            ]
          }
        ]
      })

      assert {:ok, [imported]} = CollectionImport.parse(legacy_json)
      assert imported.name == "Legacy"
      assert imported.variables == []
      assert length(imported.requests) == 1
    end

    test "requests importados llevan collection_id apuntando a la colección nueva" do
      c = Collections.create("Parent")
      Collections.add_request(c.id, Request.new(method: "GET", url: "https://x"))
      [stored] = Collections.list() |> Enum.filter(&(&1.id == c.id))

      json = CollectionExport.to_json(stored)
      {:ok, [imported]} = CollectionImport.parse(json)

      assert [%Request{collection_id: cid}] = imported.requests
      assert cid == imported.id
      # Y NO es el id de la colección original
      refute cid == stored.id
    end
  end
end
