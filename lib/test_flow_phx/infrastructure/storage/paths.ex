defmodule TestFlowPhx.Infrastructure.Storage.Paths do
  @moduledoc """
  Infrastructure: resolves the on-disk layout for storage.

  Defaults to `<project_root>/data/` so the directory ships with the repo
  (tracked via `data/.gitkeep`) but all contents are git-ignored. Honors
  `TEST_FLOW_DATA_DIR` so tests can stay hermetic.

  Layout:

      data/
        state.json                          # app state (collections + tabs + history index)
        <protocol>/                         # one folder per protocol (rest, graphql, ws, ...)
          <YYYY-MM-DD>/                     # ISO date of the run
            <epoch_ms>.<ext>                # one file per executed test, body in native format

  Per-execution files are written at send time. Their metadata (request
  snapshot, status, headers, timing) lives in `state.json`'s history entry,
  which holds a pointer to the body file path.
  """

  @type protocol :: :rest | :graphql | :websocket | atom()

  @spec data_dir() :: Path.t()
  def data_dir do
    case System.get_env("TEST_FLOW_DATA_DIR") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(File.cwd!(), "data")
    end
  end

  @spec state_file() :: Path.t()
  def state_file, do: Path.join(data_dir(), "state.json")

  @spec result_dir(protocol(), Date.t()) :: Path.t()
  def result_dir(protocol, %Date{} = date) do
    Path.join([data_dir(), to_string(protocol), Date.to_iso8601(date)])
  end

  @doc """
  Build the path for a per-execution result file.

  `epoch_ms` defaults to `System.os_time(:millisecond)` at call time.
  `ext` is the file extension without the leading dot (e.g. "json", "txt").
  The parent directory is NOT created — callers do `File.mkdir_p!/1`.
  """
  @spec result_file(protocol(), Date.t(), pos_integer(), String.t()) :: Path.t()
  def result_file(protocol, %Date{} = date, epoch_ms, ext)
      when is_integer(epoch_ms) and is_binary(ext) do
    Path.join(result_dir(protocol, date), "#{epoch_ms}.#{ext}")
  end

  @doc """
  Convenience: build a result path for "now" (UTC date, current epoch ms),
  picking the extension from a response Content-Type header value.
  """
  @spec result_file_now(protocol(), String.t() | nil) :: Path.t()
  def result_file_now(protocol, content_type) do
    result_file(protocol, Date.utc_today(), now_epoch_ms(), extension_for(content_type))
  end

  @spec now_epoch_ms() :: integer()
  def now_epoch_ms, do: System.os_time(:millisecond)

  @doc """
  Map a Content-Type header value to a sensible file extension.
  Falls back to "bin" for unknown or missing types.
  """
  @spec extension_for(String.t() | nil) :: String.t()
  def extension_for(nil), do: "bin"

  def extension_for(content_type) when is_binary(content_type) do
    base =
      content_type
      |> String.downcase()
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()

    cond do
      base in ["application/json", "application/ld+json", "application/problem+json"] -> "json"
      String.ends_with?(base, "+json") -> "json"
      String.ends_with?(base, "+xml") -> "xml"
      true -> known_or_subtype(base)
    end
  end

  defp known_or_subtype(base) do
    case base do
      "application/xml" -> "xml"
      "text/xml" -> "xml"
      "application/javascript" -> "js"
      "application/x-www-form-urlencoded" -> "txt"
      "text/plain" -> "txt"
      "text/html" -> "html"
      "text/css" -> "css"
      "text/csv" -> "csv"
      "image/png" -> "png"
      "image/jpeg" -> "jpg"
      "image/gif" -> "gif"
      "image/svg+xml" -> "svg"
      "application/pdf" -> "pdf"
      "application/octet-stream" -> "bin"
      "application/" <> rest -> sanitize_ext(rest)
      "text/" <> rest -> sanitize_ext(rest)
      _ -> "bin"
    end
  end

  defp sanitize_ext(s) do
    s
    |> String.split(["+", ";"], parts: 2)
    |> List.first()
    |> String.replace(~r/[^a-z0-9]/, "")
    |> case do
      "" -> "bin"
      ext -> ext
    end
  end
end
