defmodule TestFlowPhx.UseCases.Grpc.GrpcCollectionExportImportTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.Grpc.{Collection, Request}
  alias TestFlowPhx.Infrastructure.Storage.{GrpcJsonFileRepo, Paths}

  alias TestFlowPhx.UseCases.Grpc.{
    GrpcCollectionExport,
    GrpcCollectionImport,
    GrpcCollections,
    GrpcProtoSets
  }

  @solo """
  syntax = "proto3";
  package solo;
  message R { string a = 1; }
  service S { rpc U(R) returns (R); }
  """

  setup do
    tmp = Path.join(System.tmp_dir!(), "tf_grpc_exim_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.rm_rf(Paths.proto_sets_dir())

    on_exit(fn ->
      File.rm_rf!(tmp)
      File.rm_rf(Paths.proto_sets_dir())
    end)

    start_supervised!(
      {GrpcJsonFileRepo,
       name: GrpcJsonFileRepo, path: Path.join(tmp, "state.json"), flush_after_ms: 5}
    )

    :ok
  end

  defp seeded_collection(name) do
    c = GrpcCollections.create(name)

    GrpcCollections.add_request(
      c.id,
      Request.new(name: "#{name}-1", target: "host:1", method: "Echo")
    )

    GrpcCollections.add_request(
      c.id,
      Request.new(name: "#{name}-2", target: "host:2", method: "Down")
    )

    GrpcCollections.list() |> Enum.find(&(&1.id == c.id))
  end

  describe "GrpcCollectionExport.build/1" do
    test "single collection envelope" do
      c = seeded_collection("Smoke")
      env = GrpcCollectionExport.build(c)

      assert env["format"] == "testflow-grpc-collection"
      assert env["version"] == 2
      assert is_binary(env["exported_at"])
      assert [%{"name" => "Smoke", "requests" => reqs, "variables" => []}] = env["collections"]
      assert length(reqs) == 2

      # IDs y collection_id stripped del export para que import no colisione.
      assert Enum.all?(reqs, fn r -> not Map.has_key?(r, "id") end)
      assert Enum.all?(reqs, fn r -> not Map.has_key?(r, "collection_id") end)
      # Pero los campos gRPC sí viajan.
      assert Enum.all?(reqs, fn r -> Map.has_key?(r, "target") and Map.has_key?(r, "method") end)
    end

    test "multiple collections envelope" do
      a = seeded_collection("A")
      b = seeded_collection("B")
      env = GrpcCollectionExport.build([a, b])

      assert Enum.map(env["collections"], & &1["name"]) == ["A", "B"]
    end

    test "to_json/1 produces valid JSON" do
      c = seeded_collection("J")
      json = GrpcCollectionExport.to_json(c)
      assert {:ok, %{"format" => "testflow-grpc-collection"}} = Jason.decode(json)
    end
  end

  describe "GrpcCollectionImport.parse/1" do
    test "parses a self-produced export back con IDs frescos" do
      c = seeded_collection("Round Trip")
      json = GrpcCollectionExport.to_json(c)

      assert {:ok, [imported]} = GrpcCollectionImport.parse(json)
      assert %Collection{name: "Round Trip", requests: [_, _]} = imported

      assert is_binary(imported.id) and imported.id != c.id
      assert Enum.all?(imported.requests, &(is_binary(&1.id) and &1.id != ""))
      # los campos gRPC se preservan
      assert Enum.map(imported.requests, & &1.method) == ["Echo", "Down"]
    end

    test "rejects invalid JSON" do
      assert {:error, :invalid_json} = GrpcCollectionImport.parse("not json")
    end

    test "rejects unknown format" do
      assert {:error, :unknown_format} =
               GrpcCollectionImport.parse(~s({"format":"postman","version":1}))
    end

    test "rechaza un export REST (testflow-collection): los shapes no son intercambiables" do
      rest_export =
        ~s({"format":"testflow-collection","version":2,"collections":[{"name":"R","requests":[]}]})

      assert {:error, :unknown_format} = GrpcCollectionImport.parse(rest_export)
    end

    test "rejects unsupported version" do
      assert {:error, :unsupported_version} =
               GrpcCollectionImport.parse(
                 ~s({"format":"testflow-grpc-collection","version":99,"collections":[]})
               )
    end

    test "rejects malformed envelopes (missing collections list)" do
      assert {:error, :malformed} =
               GrpcCollectionImport.parse(~s({"format":"testflow-grpc-collection","version":1}))
    end
  end

  describe "GrpcCollectionImport.import_all/1" do
    test "persists each collection and returns the count" do
      a = seeded_collection("Alpha")
      b = seeded_collection("Beta")
      json = GrpcCollectionExport.to_json([a, b])

      GrpcCollections.clear()
      assert GrpcCollections.list() == []

      assert {:ok, 2} = GrpcCollectionImport.import_all(json)
      assert length(GrpcCollections.list()) == 2
      assert GrpcCollections.list() |> Enum.map(& &1.name) |> Enum.sort() == ["Alpha", "Beta"]
    end

    test "importing the same file twice appends — never overwrites" do
      c = seeded_collection("Dup")
      json = GrpcCollectionExport.to_json(c)

      assert {:ok, 1} = GrpcCollectionImport.import_all(json)
      assert {:ok, 1} = GrpcCollectionImport.import_all(json)
      assert GrpcCollections.list() |> Enum.count(&(&1.name == "Dup")) == 3
    end
  end

  describe "proto-sets (v2): referencia por nombre, sin .proto" do
    test "export referencia el proto-set por NOMBRE y omite id/rutas locales" do
      {:ok, set} = GrpcProtoSets.create_from_file(@solo, "solo.proto", name: "myset")

      c = GrpcCollections.create("WithSet")

      GrpcCollections.add_request(
        c.id,
        Request.new(
          name: "r",
          target: "host:1",
          proto_set_id: set.id,
          entry_file: "solo.proto",
          service: "solo.S",
          method: "U"
        )
      )

      [stored] = GrpcCollections.list() |> Enum.filter(&(&1.id == c.id))
      env = Jason.decode!(GrpcCollectionExport.to_json(stored))
      req = env["collections"] |> hd() |> Map.fetch!("requests") |> hd()

      assert req["proto_set"] == "myset"
      assert req["entry_file"] == "solo.proto"
      assert req["service"] == "solo.S"
      refute Map.has_key?(req, "proto_set_id")
      refute Map.has_key?(req, "proto_paths")
      refute Map.has_key?(req, "import_paths")
    end

    test "import re-enlaza al proto-set local con el mismo nombre" do
      {:ok, set} = GrpcProtoSets.create_from_file(@solo, "solo.proto", name: "linkme")

      c = GrpcCollections.create("ToExport")

      GrpcCollections.add_request(
        c.id,
        Request.new(name: "r", proto_set_id: set.id, entry_file: "solo.proto", method: "U")
      )

      [stored] = GrpcCollections.list() |> Enum.filter(&(&1.id == c.id))
      json = GrpcCollectionExport.to_json(stored)

      {:ok, [imported]} = GrpcCollectionImport.parse(json)
      [ireq] = imported.requests

      assert ireq.proto_set_id == set.id
      assert ireq.entry_file == "solo.proto"
    end

    test "import con proto-set inexistente → request sin proto (proto_set_id nil)" do
      json = ~s({"format":"testflow-grpc-collection","version":2,"collections":[
        {"name":"C","variables":[],"requests":[
          {"name":"r","target":"h:1","service":"solo.S","method":"U",
           "proto_set":"fantasma","entry_file":"solo.proto"}]}]})

      {:ok, [imported]} = GrpcCollectionImport.parse(json)
      [ireq] = imported.requests

      assert ireq.proto_set_id == nil
      assert ireq.entry_file == "solo.proto"
    end

    test "back-compat: importa un sobre v1 con proto_paths locales" do
      json = ~s({"format":"testflow-grpc-collection","version":1,"collections":[
        {"name":"old","variables":[],"requests":[
          {"name":"r","target":"x:1","method":"Echo","proto_paths":["/abs/x.proto"]}]}]})

      {:ok, [imported]} = GrpcCollectionImport.parse(json)
      [ireq] = imported.requests

      assert ireq.proto_paths == ["/abs/x.proto"]
      assert ireq.proto_set_id == nil
    end
  end

  describe "variables + collection_id" do
    test "round-trip preserva variables de colección" do
      c = GrpcCollections.create("With Vars")

      :ok =
        GrpcCollections.set_variables(c.id, [
          %{name: "host", value: "9.9.9.9:1", enabled: true},
          %{name: "off", value: "x", enabled: false}
        ])

      [stored] = GrpcCollections.list() |> Enum.filter(&(&1.id == c.id))
      json = GrpcCollectionExport.to_json(stored)

      assert {:ok, [imported]} = GrpcCollectionImport.parse(json)

      assert imported.variables == [
               %{name: "host", value: "9.9.9.9:1", enabled: true},
               %{name: "off", value: "x", enabled: false}
             ]
    end

    test "requests importados llevan collection_id de la colección nueva" do
      c = GrpcCollections.create("Parent")
      GrpcCollections.add_request(c.id, Request.new(name: "r", target: "x:1", method: "Echo"))
      [stored] = GrpcCollections.list() |> Enum.filter(&(&1.id == c.id))

      json = GrpcCollectionExport.to_json(stored)
      {:ok, [imported]} = GrpcCollectionImport.parse(json)

      assert [%Request{collection_id: cid}] = imported.requests
      assert cid == imported.id
      refute cid == stored.id
    end
  end
end
