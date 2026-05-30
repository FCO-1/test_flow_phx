defmodule TestFlowPhx.Infrastructure.Storage.GrpcSerializer do
  @moduledoc """
  Infrastructure: round-trip de entidades de dominio **gRPC** a mapas con
  llaves string, apto para `Jason`.

  Módulo aparte del `Serializer` (REST) a propósito (N.11): el store gRPC vive
  en su propio archivo (`data/grpc/state.json`) y el shape de `Grpc.Request`
  es distinto (target/service/method/proto_paths/metadata en vez de
  method/url/headers/auth). No hay valores atom que mapear acá — el tipo de
  RPC lo dicta el descriptor, no el struct — así que load/dump es directo.
  """

  alias TestFlowPhx.Domain.Grpc.{Collection, HistoryEntry, Request}

  # ----- dump (struct → map) -----

  def dump_document(%{
        collections: collections,
        tabs: tabs,
        active_tab_id: active_tab_id
      } = doc) do
    %{
      "version" => 1,
      "collections" => Enum.map(collections, &dump_collection/1),
      "history" => doc |> Map.get(:history, []) |> Enum.map(&dump_history/1),
      "tabs" => Enum.map(tabs, &dump_request/1),
      "active_tab_id" => active_tab_id
    }
  end

  def dump_request(%Request{} = r) do
    %{
      "id" => r.id,
      "name" => r.name,
      "target" => r.target,
      "proto_set_id" => r.proto_set_id,
      "entry_file" => r.entry_file,
      "proto_paths" => r.proto_paths,
      "import_paths" => r.import_paths,
      "service" => r.service,
      "method" => r.method,
      "metadata" => dump_kv_rows(r.metadata),
      "body_text" => r.body_text,
      "collection_id" => r.collection_id
    }
  end

  def dump_collection(%Collection{} = c) do
    %{
      "id" => c.id,
      "name" => c.name,
      "requests" => Enum.map(c.requests, &dump_request/1),
      "variables" => dump_variables(c.variables)
    }
  end

  def dump_variables(rows) when is_list(rows), do: Enum.map(rows, &dump_variable/1)
  def dump_variables(_), do: []

  defp dump_variable(%{name: n, value: v, enabled: e}),
    do: %{"name" => n, "value" => v, "enabled" => e}

  defp dump_kv_rows(rows) when is_list(rows), do: Enum.map(rows, &dump_kv_row/1)
  defp dump_kv_rows(_), do: []

  defp dump_kv_row(%{key: k, value: v, enabled: e}),
    do: %{"key" => k, "value" => v, "enabled" => e}

  # ----- load (map → struct) -----

  def load_document(nil), do: empty_document()
  def load_document(map) when map == %{}, do: empty_document()

  def load_document(map) when is_map(map) do
    %{
      collections: map |> Map.get("collections", []) |> Enum.map(&load_collection/1),
      history: map |> Map.get("history", []) |> Enum.map(&load_history/1),
      tabs: map |> Map.get("tabs", []) |> Enum.map(&load_request/1),
      active_tab_id: Map.get(map, "active_tab_id")
    }
  end

  def empty_document do
    %{collections: [], history: [], tabs: [], active_tab_id: nil}
  end

  def load_request(map) when is_map(map) do
    %Request{
      id: map["id"],
      name: map["name"] || "Untitled",
      target: map["target"] || "",
      proto_set_id: map["proto_set_id"],
      entry_file: map["entry_file"],
      proto_paths: load_string_list(map["proto_paths"]),
      import_paths: load_string_list(map["import_paths"]),
      service: map["service"] || "",
      method: map["method"] || "",
      metadata: load_kv_rows(map["metadata"]),
      body_text: map["body_text"] || "",
      collection_id: map["collection_id"]
    }
  end

  def load_collection(map) when is_map(map) do
    %Collection{
      id: map["id"],
      name: map["name"] || "",
      requests: map |> Map.get("requests", []) |> Enum.map(&load_request/1),
      variables: load_variables(map["variables"])
    }
  end

  def load_variables(rows) when is_list(rows) do
    Enum.map(rows, fn r ->
      %{
        name: r["name"] || "",
        value: r["value"] || "",
        enabled: Map.get(r, "enabled", true)
      }
    end)
  end

  def load_variables(_), do: []

  defp load_kv_rows(rows) when is_list(rows) do
    Enum.map(rows, fn r ->
      %{
        key: r["key"] || "",
        value: r["value"] || "",
        enabled: Map.get(r, "enabled", true)
      }
    end)
  end

  defp load_kv_rows(_), do: []

  defp load_string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp load_string_list(_), do: []

  # ----- history (struct ↔ map) -----

  def dump_history(%HistoryEntry{} = h) do
    %{
      "id" => h.id,
      "ran_at" => h.ran_at && DateTime.to_iso8601(h.ran_at),
      "request" => h.request && dump_request(h.request),
      "response_status" => h.response_status,
      "response_message" => h.response_message,
      "streaming?" => h.streaming?,
      "message_count" => h.message_count,
      "response_duration_ms" => h.response_duration_ms,
      "response_error" => dump_error(h.response_error),
      "result_file" => h.result_file
    }
  end

  def load_history(map) when is_map(map) do
    %HistoryEntry{
      id: map["id"],
      ran_at: parse_datetime(map["ran_at"]),
      request: map["request"] && load_request(map["request"]),
      response_status: map["response_status"],
      response_message: map["response_message"],
      streaming?: Map.get(map, "streaming?", false),
      message_count: map["message_count"] || 0,
      response_duration_ms: map["response_duration_ms"] || 0,
      response_error: load_error(map["response_error"]),
      result_file: map["result_file"]
    }
  end

  defp dump_error(nil), do: nil

  defp dump_error(err) when is_map(err) do
    %{
      "type" => err |> Map.get(:type) |> to_string_or_nil(),
      "message" => Map.get(err, :message, ""),
      "code" => Map.get(err, :code)
    }
  end

  defp load_error(nil), do: nil

  defp load_error(map) when is_map(map) do
    %{
      type: parse_atom(map["type"]),
      message: map["message"] || "",
      code: map["code"]
    }
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(a) when is_atom(a), do: Atom.to_string(a)
  defp to_string_or_nil(s) when is_binary(s), do: s

  # Los tipos de error gRPC son un set conocido y acotado; convertir por
  # existencia evita inflar la tabla de átomos desde datos en disco.
  @error_types ~w(proto_load invalid_json invalid_request transport grpc unknown)
  defp parse_atom(s) when is_binary(s) and s in @error_types, do: String.to_existing_atom(s)
  defp parse_atom(_), do: :unknown

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
