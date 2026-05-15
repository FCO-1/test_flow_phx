defmodule TestFlowPhx.Infrastructure.Storage.Serializer do
  @moduledoc """
  Infrastructure: round-trips domain entities through string-keyed maps
  suitable for `Jason.encode!/1` / `Jason.decode!/1`.

  Atom values (body_type, auth.type, auth.in, form_row.type, error.type)
  are emitted as strings on `dump` and converted back from a whitelist on
  `load`. Never uses `String.to_atom/1` on untrusted input.
  """

  alias TestFlowPhx.Domain.{Collection, HistoryEntry, Request}

  @body_types ~w(none json raw form_urlencoded multipart)
  @auth_types ~w(none bearer api_key)
  @auth_locations ~w(header query)
  @form_row_types ~w(text file)
  @error_types ~w(invalid_json invalid_request timeout network unknown)

  # ----- dump (struct → map) -----

  def dump_document(%{
        collections: collections,
        history: history,
        tabs: tabs,
        active_tab_id: active_tab_id
      }) do
    %{
      "version" => 1,
      "collections" => Enum.map(collections, &dump_collection/1),
      "history" => Enum.map(history, &dump_history/1),
      "tabs" => Enum.map(tabs, &dump_request/1),
      "active_tab_id" => active_tab_id
    }
  end

  def dump_request(%Request{} = r) do
    %{
      "id" => r.id,
      "name" => r.name,
      "method" => r.method,
      "url" => r.url,
      "query_params" => dump_kv_rows(r.query_params),
      "headers" => dump_kv_rows(r.headers),
      "body_type" => Atom.to_string(r.body_type),
      "body_text" => r.body_text,
      "body_form" => Enum.map(r.body_form, &dump_form_row/1),
      "auth" => dump_auth(r.auth)
    }
  end

  def dump_collection(%Collection{} = c) do
    %{
      "id" => c.id,
      "name" => c.name,
      "requests" => Enum.map(c.requests, &dump_request/1)
    }
  end

  def dump_history(%HistoryEntry{} = h) do
    %{
      "id" => h.id,
      "ran_at" => h.ran_at && DateTime.to_iso8601(h.ran_at),
      "request" => h.request && dump_request(h.request),
      "response_status" => h.response_status,
      "response_duration_ms" => h.response_duration_ms,
      "response_size_bytes" => h.response_size_bytes,
      "response_error" => dump_error(h.response_error),
      "result_file" => h.result_file
    }
  end

  defp dump_kv_rows(rows), do: Enum.map(rows, &dump_kv_row/1)

  defp dump_kv_row(%{key: k, value: v, enabled: e}),
    do: %{"key" => k, "value" => v, "enabled" => e}

  defp dump_form_row(%{key: k, value: v, enabled: e, type: t, file_path: fp}) do
    %{
      "key" => k,
      "value" => v,
      "enabled" => e,
      "type" => Atom.to_string(t),
      "file_path" => fp
    }
  end

  defp dump_auth(%{type: :none}), do: %{"type" => "none"}

  defp dump_auth(%{type: :bearer, token: t}),
    do: %{"type" => "bearer", "token" => t}

  defp dump_auth(%{type: :api_key, key: k, value: v, in: loc}) do
    %{
      "type" => "api_key",
      "key" => k,
      "value" => v,
      "in" => Atom.to_string(loc)
    }
  end

  defp dump_error(nil), do: nil

  defp dump_error(%{type: t} = err) do
    %{"type" => Atom.to_string(t), "message" => Map.get(err, :message, "")}
  end

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
      method: map["method"] || "GET",
      url: map["url"] || "",
      query_params: load_kv_rows(map["query_params"]),
      headers: load_kv_rows(map["headers"]),
      body_type: load_atom(map["body_type"], @body_types, :none),
      body_text: map["body_text"] || "",
      body_form: load_form_rows(map["body_form"]),
      auth: load_auth(map["auth"])
    }
  end

  def load_collection(map) when is_map(map) do
    %Collection{
      id: map["id"],
      name: map["name"] || "",
      requests: map |> Map.get("requests", []) |> Enum.map(&load_request/1)
    }
  end

  def load_history(map) when is_map(map) do
    %HistoryEntry{
      id: map["id"],
      ran_at: parse_datetime(map["ran_at"]),
      request: map["request"] && load_request(map["request"]),
      response_status: map["response_status"],
      response_duration_ms: map["response_duration_ms"] || 0,
      response_size_bytes: map["response_size_bytes"] || 0,
      response_error: load_error(map["response_error"]),
      result_file: map["result_file"]
    }
  end

  defp load_kv_rows(nil), do: []

  defp load_kv_rows(rows) when is_list(rows) do
    Enum.map(rows, fn r ->
      %{
        key: r["key"] || "",
        value: r["value"] || "",
        enabled: Map.get(r, "enabled", true)
      }
    end)
  end

  defp load_form_rows(nil), do: []

  defp load_form_rows(rows) when is_list(rows) do
    Enum.map(rows, fn r ->
      %{
        key: r["key"] || "",
        value: r["value"] || "",
        enabled: Map.get(r, "enabled", true),
        type: load_atom(r["type"], @form_row_types, :text),
        file_path: r["file_path"]
      }
    end)
  end

  defp load_auth(nil), do: %{type: :none}

  defp load_auth(map) when is_map(map) do
    case load_atom(map["type"], @auth_types, :none) do
      :none ->
        %{type: :none}

      :bearer ->
        %{type: :bearer, token: map["token"] || ""}

      :api_key ->
        %{
          type: :api_key,
          key: map["key"] || "",
          value: map["value"] || "",
          in: load_atom(map["in"], @auth_locations, :header)
        }
    end
  end

  defp load_error(nil), do: nil

  defp load_error(map) when is_map(map) do
    %{
      type: load_atom(map["type"], @error_types, :unknown),
      message: map["message"] || ""
    }
  end

  defp load_atom(value, whitelist, default) when is_binary(value) do
    if value in whitelist, do: String.to_existing_atom(value), else: default
  end

  defp load_atom(_other, _whitelist, default), do: default

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
