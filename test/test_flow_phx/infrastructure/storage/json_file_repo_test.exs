defmodule TestFlowPhx.Infrastructure.Storage.JsonFileRepoTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.{Collection, HistoryEntry, Request}
  alias TestFlowPhx.Infrastructure.Storage.{JsonFileRepo, Serializer}

  setup do
    tmp = Path.join(System.tmp_dir!(), "test_flow_repo_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    path = Path.join(tmp, "state.json")

    pid =
      start_supervised!(
        {JsonFileRepo, name: JsonFileRepo, path: path, flush_after_ms: 10, history_cap: 5}
      )

    {:ok, repo: pid, path: path, tmp: tmp}
  end

  describe "collections" do
    test "upserts and lists collections", _ do
      c = %Collection{id: "c1", name: "Smoke", requests: []}
      assert :ok = JsonFileRepo.upsert_collection(c)

      [stored] = JsonFileRepo.list_collections()
      assert stored.id == "c1"
      assert stored.name == "Smoke"
    end

    test "assigns an id when missing", _ do
      :ok = JsonFileRepo.upsert_collection(%Collection{name: "no-id"})
      [stored] = JsonFileRepo.list_collections()
      assert is_binary(stored.id) and stored.id != ""
    end

    test "updates an existing collection in place", _ do
      :ok = JsonFileRepo.upsert_collection(%Collection{id: "c1", name: "Old"})
      :ok = JsonFileRepo.upsert_collection(%Collection{id: "c1", name: "New"})

      assert [%Collection{name: "New"}] = JsonFileRepo.list_collections()
    end

    test "deletes by id", _ do
      :ok = JsonFileRepo.upsert_collection(%Collection{id: "c1", name: "X"})
      :ok = JsonFileRepo.delete_collection("c1")
      assert JsonFileRepo.list_collections() == []
    end
  end

  describe "requests inside collections" do
    test "upsert + delete requests inside a collection", _ do
      :ok = JsonFileRepo.upsert_collection(%Collection{id: "c1", name: "C"})

      :ok =
        JsonFileRepo.upsert_request_in(
          "c1",
          Request.new(id: "r1", method: "GET", url: "https://x")
        )

      [c] = JsonFileRepo.list_collections()
      assert Enum.map(c.requests, & &1.id) == ["r1"]

      :ok = JsonFileRepo.delete_request_in("c1", "r1")
      [c] = JsonFileRepo.list_collections()
      assert c.requests == []
    end
  end

  describe "history" do
    test "appends newest first and caps", _ do
      for i <- 1..7 do
        :ok =
          JsonFileRepo.append_history(%HistoryEntry{
            id: "h#{i}",
            ran_at: DateTime.utc_now(),
            request: Request.new(method: "GET", url: "https://x/#{i}"),
            response_status: 200
          })
      end

      ids = JsonFileRepo.list_history(10) |> Enum.map(& &1.id)
      assert length(ids) == 5
      assert ids == ["h7", "h6", "h5", "h4", "h3"]
    end

    test "clear_history empties it", _ do
      :ok =
        JsonFileRepo.append_history(%HistoryEntry{
          id: "h1",
          ran_at: DateTime.utc_now(),
          request: Request.new(method: "GET", url: "https://x")
        })

      :ok = JsonFileRepo.clear_history()
      assert JsonFileRepo.list_history(10) == []
    end
  end

  describe "tabs" do
    test "set_tabs updates both the list and the active id", _ do
      tabs = [
        Request.new(id: "t1", method: "GET", url: "https://x/1"),
        Request.new(id: "t2", method: "POST", url: "https://x/2")
      ]

      :ok = JsonFileRepo.set_tabs(tabs, "t2")
      assert Enum.map(JsonFileRepo.list_tabs(), & &1.id) == ["t1", "t2"]
      assert JsonFileRepo.active_tab_id() == "t2"
    end
  end

  describe "disk persistence" do
    test "flushes to JSON file after debounce", %{path: path} do
      :ok = JsonFileRepo.upsert_collection(%Collection{id: "c1", name: "Persisted"})

      assert eventually(fn -> File.exists?(path) end)

      doc =
        path
        |> File.read!()
        |> Jason.decode!()
        |> Serializer.load_document()

      assert [%Collection{id: "c1", name: "Persisted"}] = doc.collections
    end

    test "restart reads existing data", %{path: path} do
      :ok = JsonFileRepo.upsert_collection(%Collection{id: "c1", name: "Survives"})
      assert eventually(fn -> File.exists?(path) end)

      :ok = stop_supervised(JsonFileRepo)

      _pid =
        start_supervised!({JsonFileRepo, name: JsonFileRepo, path: path, flush_after_ms: 10})

      assert [%Collection{name: "Survives"}] = JsonFileRepo.list_collections()
    end
  end

  describe "pubsub" do
    test "broadcasts :storage_changed on writes", _ do
      Phoenix.PubSub.subscribe(TestFlowPhx.PubSub, "storage")

      :ok = JsonFileRepo.upsert_collection(%Collection{id: "c1", name: "Pinged"})
      assert_receive :storage_changed, 200
    end
  end

  defp eventually(check, attempts \\ 50, sleep_ms \\ 10) do
    Enum.reduce_while(1..attempts, false, fn _i, _acc ->
      if check.() do
        {:halt, true}
      else
        Process.sleep(sleep_ms)
        {:cont, false}
      end
    end)
  end
end
