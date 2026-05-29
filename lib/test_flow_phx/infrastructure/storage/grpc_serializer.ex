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

  alias TestFlowPhx.Domain.Grpc.{Collection, Request}

  # ----- dump (struct → map) -----

  def dump_document(%{collections: collections, tabs: tabs, active_tab_id: active_tab_id}) do
    %{
      "version" => 1,
      "collections" => Enum.map(collections, &dump_collection/1),
      "tabs" => Enum.map(tabs, &dump_request/1),
      "active_tab_id" => active_tab_id
    }
  end

  def dump_request(%Request{} = r) do
    %{
      "id" => r.id,
      "name" => r.name,
      "target" => r.target,
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
      tabs: map |> Map.get("tabs", []) |> Enum.map(&load_request/1),
      active_tab_id: Map.get(map, "active_tab_id")
    }
  end

  def empty_document do
    %{collections: [], tabs: [], active_tab_id: nil}
  end

  def load_request(map) when is_map(map) do
    %Request{
      id: map["id"],
      name: map["name"] || "Untitled",
      target: map["target"] || "",
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
end
