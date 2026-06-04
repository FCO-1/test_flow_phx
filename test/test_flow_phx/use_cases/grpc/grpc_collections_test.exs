defmodule TestFlowPhx.UseCases.Grpc.GrpcCollectionsTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.Grpc.{Collection, Request}
  alias TestFlowPhx.Infrastructure.Storage.GrpcJsonFileRepo, as: Repo
  alias TestFlowPhx.UseCases.Grpc.GrpcCollections

  setup do
    tmp = Path.join(System.tmp_dir!(), "tf_grpc_uc_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    start_supervised!({Repo, name: Repo, path: Path.join(tmp, "state.json"), flush_after_ms: 10})
    :ok
  end

  test "create assigns an id and persists" do
    coll = GrpcCollections.create("APIs gRPC")

    assert %Collection{} = coll
    assert is_binary(coll.id) and coll.id != ""
    assert [%Collection{id: id, name: "APIs gRPC"}] = GrpcCollections.list()
    assert id == coll.id
  end

  test "rename updates the name; :not_found for unknown id" do
    coll = GrpcCollections.create("Old")
    assert :ok = GrpcCollections.rename(coll.id, "New")
    assert [%Collection{name: "New"}] = GrpcCollections.list()
    assert {:error, :not_found} = GrpcCollections.rename("nope", "X")
  end

  test "add_request stamps the collection_id and stores it" do
    coll = GrpcCollections.create("C")
    req = GrpcCollections.add_request(coll.id, %Request{name: "Echo"})

    assert req.collection_id == coll.id
    assert is_binary(req.id) and req.id != ""

    [stored] = GrpcCollections.list()
    assert [%Request{name: "Echo", collection_id: cid}] = stored.requests
    assert cid == coll.id
  end

  test "remove_request deletes it from the collection" do
    coll = GrpcCollections.create("C")
    req = GrpcCollections.add_request(coll.id, %Request{name: "Echo"})
    :ok = GrpcCollections.remove_request(coll.id, req.id)

    [stored] = GrpcCollections.list()
    assert stored.requests == []
  end

  test "set_variables replaces the collection vars; :not_found for unknown id" do
    coll = GrpcCollections.create("C")
    vars = [%{name: "host", value: "1.2.3.4:9000", enabled: true}]

    assert :ok = GrpcCollections.set_variables(coll.id, vars)
    assert [%Collection{variables: ^vars}] = GrpcCollections.list()
    assert {:error, :not_found} = GrpcCollections.set_variables("nope", vars)
  end

  test "delete and clear" do
    a = GrpcCollections.create("A")
    _b = GrpcCollections.create("B")
    :ok = GrpcCollections.delete(a.id)
    assert [%Collection{name: "B"}] = GrpcCollections.list()
    :ok = GrpcCollections.clear()
    assert [] = GrpcCollections.list()
  end
end
