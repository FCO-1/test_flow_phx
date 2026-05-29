defmodule TestFlowPhx.Infrastructure.Storage.SerializerTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Domain.{Collection, HistoryEntry, Rest.Request}
  alias TestFlowPhx.Infrastructure.Storage.Serializer

  describe "request round-trip" do
    test "dumps and loads back an equivalent Request" do
      req =
        Request.new(
          id: "abc",
          name: "Ping",
          method: "POST",
          url: "https://example.test/x",
          query_params: [%{key: "a", value: "1", enabled: true}],
          headers: [%{key: "X-H", value: "yes", enabled: true}],
          body_type: :json,
          body_text: ~s({"a":1}),
          body_form: [
            %{key: "f", value: "v", enabled: true, type: :text, file_path: nil},
            %{key: "g", value: "", enabled: false, type: :file, file_path: "/tmp/x"}
          ],
          auth: %{type: :bearer, token: "t"}
        )

      assert ^req = req |> Serializer.dump_request() |> Serializer.load_request()
    end

    test "auth :api_key with :query location round-trips" do
      req =
        Request.new(
          method: "GET",
          url: "https://example.test/",
          auth: %{type: :api_key, key: "k", value: "v", in: :query}
        )

      loaded = req |> Serializer.dump_request() |> Serializer.load_request()
      assert loaded.auth == %{type: :api_key, key: "k", value: "v", in: :query}
    end

    test "unknown body_type loads as :none fallback" do
      bad = Serializer.dump_request(Request.new()) |> Map.put("body_type", "bogus")
      loaded = Serializer.load_request(bad)
      assert loaded.body_type == :none
    end
  end

  describe "history entry round-trip" do
    test "preserves DateTime via ISO8601" do
      dt = ~U[2026-05-15 12:34:56.000Z]

      entry = %HistoryEntry{
        id: "h1",
        ran_at: dt,
        request: Request.new(method: "GET", url: "https://x.test"),
        response_status: 200,
        response_duration_ms: 12,
        response_size_bytes: 34,
        response_error: nil,
        result_file: "data/rest/2026-05-15/123.json"
      }

      loaded = entry |> Serializer.dump_history() |> Serializer.load_history()

      assert loaded.id == "h1"
      assert DateTime.compare(loaded.ran_at, dt) == :eq
      assert loaded.response_status == 200
      assert loaded.result_file == "data/rest/2026-05-15/123.json"
    end

    test "preserves response_error with whitelisted type" do
      entry = %HistoryEntry{
        id: "h2",
        ran_at: DateTime.utc_now(),
        request: Request.new(method: "GET", url: "https://x.test"),
        response_error: %{type: :timeout, message: "slow"}
      }

      loaded = entry |> Serializer.dump_history() |> Serializer.load_history()
      assert loaded.response_error == %{type: :timeout, message: "slow"}
    end
  end

  describe "collection round-trip" do
    test "preserves nested requests" do
      coll = %Collection{
        id: "c1",
        name: "Smoke",
        requests: [
          Request.new(id: "r1", method: "GET", url: "https://x/a"),
          Request.new(id: "r2", method: "POST", url: "https://x/b", body_type: :raw)
        ]
      }

      loaded = coll |> Serializer.dump_collection() |> Serializer.load_collection()
      assert length(loaded.requests) == 2
      assert Enum.map(loaded.requests, & &1.id) == ["r1", "r2"]
      assert Enum.at(loaded.requests, 1).body_type == :raw
    end
  end

  describe "document round-trip" do
    test "round-trips through Jason without losing data" do
      doc = %{
        collections: [%Collection{id: "c1", name: "X", requests: []}],
        history: [],
        tabs: [Request.new(id: "t1", method: "GET", url: "https://x.test")],
        active_tab_id: "t1",
        globals: []
      }

      json = doc |> Serializer.dump_document() |> Jason.encode!()
      loaded = json |> Jason.decode!() |> Serializer.load_document()

      assert loaded.active_tab_id == "t1"
      assert Enum.map(loaded.collections, & &1.id) == ["c1"]
      assert Enum.map(loaded.tabs, & &1.id) == ["t1"]
    end

    test "load_document handles nil / empty map gracefully" do
      assert Serializer.load_document(nil) == Serializer.empty_document()
      assert Serializer.load_document(%{}) == Serializer.empty_document()
    end
  end

  describe "variables (Fase M)" do
    test "request round-trip preserves collection_id" do
      req = Request.new(id: "r1", method: "GET", url: "https://x", collection_id: "c1")
      loaded = req |> Serializer.dump_request() |> Serializer.load_request()
      assert loaded.collection_id == "c1"
    end

    test "request without collection_id defaults to nil on load" do
      old_dump = Request.new(id: "r1") |> Serializer.dump_request() |> Map.delete("collection_id")
      assert %Request{collection_id: nil} = Serializer.load_request(old_dump)
    end

    test "collection round-trip preserves variables" do
      coll = %Collection{
        id: "c1",
        name: "C",
        requests: [],
        variables: [
          %{name: "base_url", value: "https://api", enabled: true},
          %{name: "muted", value: "x", enabled: false}
        ]
      }

      loaded = coll |> Serializer.dump_collection() |> Serializer.load_collection()
      assert loaded.variables == coll.variables
    end

    test "collection without variables key loads as empty list" do
      legacy = %{"id" => "c1", "name" => "C", "requests" => []}
      assert %Collection{variables: []} = Serializer.load_collection(legacy)
    end

    test "document round-trip preserves globals" do
      doc = %{
        collections: [],
        history: [],
        tabs: [],
        active_tab_id: nil,
        globals: [%{name: "g1", value: "v1", enabled: true}]
      }

      json = doc |> Serializer.dump_document() |> Jason.encode!()
      loaded = json |> Jason.decode!() |> Serializer.load_document()

      assert loaded.globals == [%{name: "g1", value: "v1", enabled: true}]
    end

    test "document without globals key loads as empty list (back-compat)" do
      legacy_json = ~s({"version":1,"collections":[],"history":[],"tabs":[],"active_tab_id":null})
      assert %{globals: []} = legacy_json |> Jason.decode!() |> Serializer.load_document()
    end
  end
end
