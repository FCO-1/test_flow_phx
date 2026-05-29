defmodule TestFlowPhx.Infrastructure.Storage.GrpcJsonFileRepoTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.Grpc.{Collection, Request}
  alias TestFlowPhx.Infrastructure.Storage.GrpcJsonFileRepo, as: Repo

  setup do
    tmp = Path.join(System.tmp_dir!(), "tf_grpc_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    path = Path.join(tmp, "state.json")
    pid = start_supervised!({Repo, name: Repo, path: path, flush_after_ms: 10})

    {:ok, repo: pid, path: path}
  end

  describe "collections" do
    test "upserts, assigns id when missing, lists" do
      :ok = Repo.upsert_collection(%Collection{name: "no-id"})
      [stored] = Repo.list_collections()
      assert is_binary(stored.id) and stored.id != ""
      assert stored.name == "no-id"
    end

    test "updates an existing collection in place" do
      :ok = Repo.upsert_collection(%Collection{id: "c1", name: "Old"})
      :ok = Repo.upsert_collection(%Collection{id: "c1", name: "New"})
      assert [%Collection{id: "c1", name: "New"}] = Repo.list_collections()
    end

    test "deletes and clears" do
      :ok = Repo.upsert_collection(%Collection{id: "c1", name: "A"})
      :ok = Repo.upsert_collection(%Collection{id: "c2", name: "B"})
      :ok = Repo.delete_collection("c1")
      assert [%Collection{id: "c2"}] = Repo.list_collections()
      :ok = Repo.clear_collections()
      assert [] = Repo.list_collections()
    end
  end

  describe "requests inside a collection" do
    test "upserts a request into the named collection only" do
      :ok = Repo.upsert_collection(%Collection{id: "c1", name: "A"})
      :ok = Repo.upsert_collection(%Collection{id: "c2", name: "B"})

      :ok = Repo.upsert_request_in("c1", %Request{id: "r1", name: "Echo"})

      [c1, c2] = Repo.list_collections()
      assert [%Request{id: "r1"}] = c1.requests
      assert [] = c2.requests
    end

    test "removes a request from a collection" do
      :ok = Repo.upsert_collection(%Collection{id: "c1", name: "A"})
      :ok = Repo.upsert_request_in("c1", %Request{id: "r1"})
      :ok = Repo.delete_request_in("c1", "r1")
      [c1] = Repo.list_collections()
      assert [] = c1.requests
    end
  end

  describe "tabs" do
    test "set_tabs persists tabs and active id" do
      tabs = [%Request{id: "r1", name: "uno"}, %Request{id: "r2", name: "dos"}]
      :ok = Repo.set_tabs(tabs, "r2")
      assert [%Request{id: "r1"}, %Request{id: "r2"}] = Repo.list_tabs()
      assert Repo.active_tab_id() == "r2"
    end
  end

  describe "persistence" do
    test "flushes to disk and reloads on restart", %{path: path} do
      :ok = Repo.upsert_collection(%Collection{id: "c1", name: "Persisted"})
      :ok = Repo.set_tabs([%Request{id: "r1", name: "tab"}], "r1")

      # Espera el flush debounced y verifica el archivo en disco.
      Process.sleep(40)
      assert File.exists?(path)

      stop_supervised!(Repo)
      start_supervised!({Repo, name: Repo, path: path, flush_after_ms: 10})

      assert [%Collection{id: "c1", name: "Persisted"}] = Repo.list_collections()
      assert [%Request{id: "r1"}] = Repo.list_tabs()
      assert Repo.active_tab_id() == "r1"
    end
  end
end
