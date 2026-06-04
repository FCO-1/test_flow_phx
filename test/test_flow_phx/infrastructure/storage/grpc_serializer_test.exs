defmodule TestFlowPhx.Infrastructure.Storage.GrpcSerializerTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Domain.Grpc.{Collection, HistoryEntry, Request}
  alias TestFlowPhx.Infrastructure.Storage.GrpcSerializer

  defp sample_request do
    %Request{
      id: "r1",
      name: "Echo",
      target: "localhost:50051",
      proto_paths: ["/data/grpc/protos/echo.proto"],
      service: "echo.Echoer",
      method: "Echo",
      metadata: [%{key: "x-token", value: "abc", enabled: true}],
      body_text: ~s({"msg":"hi"}),
      collection_id: "c1"
    }
  end

  defp sample_history do
    %HistoryEntry{
      id: "h1",
      ran_at: ~U[2026-05-30 12:00:00.000000Z],
      request: sample_request(),
      response_status: 0,
      response_message: nil,
      streaming?: false,
      message_count: 0,
      response_duration_ms: 42,
      response_error: nil,
      result_file: "data/grpc/2026-05-30/123.json"
    }
  end

  describe "request round-trip" do
    test "dump then load returns an equivalent struct" do
      req = sample_request()

      loaded =
        req
        |> GrpcSerializer.dump_request()
        |> json_round_trip()
        |> GrpcSerializer.load_request()

      assert loaded == req
    end

    test "load tolerates a sparse map with defaults" do
      loaded = GrpcSerializer.load_request(%{"name" => "x"})

      assert loaded.name == "x"
      assert loaded.target == ""
      assert loaded.proto_paths == []
      assert loaded.metadata == []
      assert loaded.body_text == ""
      assert loaded.collection_id == nil
    end

    test "load drops non-binary entries from proto_paths" do
      loaded = GrpcSerializer.load_request(%{"proto_paths" => ["ok.proto", 123, nil]})
      assert loaded.proto_paths == ["ok.proto"]
    end
  end

  describe "collection round-trip" do
    test "dump then load preserves requests and variables" do
      coll = %Collection{
        id: "c1",
        name: "Mi colección",
        requests: [sample_request()],
        variables: [%{name: "host", value: "1.2.3.4", enabled: true}]
      }

      loaded =
        coll
        |> GrpcSerializer.dump_collection()
        |> json_round_trip()
        |> GrpcSerializer.load_collection()

      assert loaded == coll
    end
  end

  describe "document round-trip" do
    test "dump then load preserves collections, history, tabs and active_tab_id" do
      doc = %{
        collections: [%Collection{id: "c1", name: "C", requests: [], variables: []}],
        history: [sample_history()],
        tabs: [sample_request()],
        active_tab_id: "r1"
      }

      loaded =
        doc
        |> GrpcSerializer.dump_document()
        |> json_round_trip()
        |> GrpcSerializer.load_document()

      assert loaded == doc
    end

    test "empty_document for nil / empty map" do
      assert GrpcSerializer.load_document(nil) == GrpcSerializer.empty_document()
      assert GrpcSerializer.load_document(%{}) == GrpcSerializer.empty_document()

      assert GrpcSerializer.empty_document() == %{
               collections: [],
               history: [],
               tabs: [],
               active_tab_id: nil
             }
    end

    test "load_document es back-compat con un doc sin la llave history" do
      legacy = %{"version" => 1, "collections" => [], "tabs" => [], "active_tab_id" => nil}
      assert %{history: []} = GrpcSerializer.load_document(legacy)
    end

    test "dump_document stamps a version" do
      assert %{"version" => 1} = GrpcSerializer.dump_document(GrpcSerializer.empty_document())
    end
  end

  describe "history round-trip" do
    test "preserva un entry de error + streaming (status, message, error, counts)" do
      entry = %HistoryEntry{
        sample_history()
        | response_status: 16,
          response_message: "CREDENCIALES_INVALIDAS: Credenciales invalidas.",
          streaming?: true,
          message_count: 3,
          response_error: %{type: :grpc, message: "boom", code: 16}
      }

      [loaded] =
        %{collections: [], history: [entry], tabs: [], active_tab_id: nil}
        |> GrpcSerializer.dump_document()
        |> json_round_trip()
        |> GrpcSerializer.load_document()
        |> Map.fetch!(:history)

      assert loaded == entry
    end
  end

  # Simula la ida/vuelta por disco (string keys) que hace el repo.
  defp json_round_trip(map), do: map |> Jason.encode!() |> Jason.decode!()
end
