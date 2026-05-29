defmodule TestFlowPhx.Infrastructure.Storage.Paths do
  @moduledoc """
  Infrastructure: resuelve el layout en disco del storage.

  Por defecto usa `<project_root>/data/` para que el directorio venga
  con el repo (trackeado vía `data/.gitkeep`) pero todo el contenido
  está git-ignored. Honra `TEST_FLOW_DATA_DIR` para que los tests sean
  herméticos.

  Layout:

      data/
        state.json                          # estado de la app (colecciones + tabs + índice de historial)
        <protocolo>/                        # una carpeta por protocolo (rest, graphql, ws, ...)
          <YYYY-MM-DD>/                     # fecha ISO de la ejecución
            <epoch_ms>.<ext>                # un archivo por ejecución, body en formato nativo

  Los archivos por ejecución se escriben al enviar. Su metadata
  (snapshot del request, status, headers, timing) vive en la entry de
  historial de `state.json`, que guarda un puntero al path del body.
  """

  @type protocol :: :rest | :graphql | :websocket | atom()

  @spec data_dir() :: Path.t()
  def data_dir do
    cond do
      (env = System.get_env("TEST_FLOW_DATA_DIR")) && env != "" ->
        env

      (override = Application.get_env(:test_flow_phx, :data_dir_override)) &&
          is_binary(override) && override != "" ->
        override

      true ->
        default_data_dir()
    end
  end

  @spec default_data_dir() :: Path.t()
  def default_data_dir, do: Path.join(File.cwd!(), "data")

  @spec state_file() :: Path.t()
  def state_file, do: Path.join(data_dir(), "state.json")

  @doc "Directorio donde se guardan los `.proto` subidos por el usuario (gRPC)."
  @spec proto_dir() :: Path.t()
  def proto_dir, do: Path.join([data_dir(), "grpc", "protos"])

  @doc """
  Directorio raíz de los proto-sets gRPC: cada set es una carpeta con el árbol
  de `.proto` (preservando la estructura de imports) + un `_manifest.json`.
  """
  @spec proto_sets_dir() :: Path.t()
  def proto_sets_dir, do: Path.join([data_dir(), "grpc", "proto_sets"])

  @doc "Directorio de un proto-set puntual (su `import_root`)."
  @spec proto_set_dir(String.t()) :: Path.t()
  def proto_set_dir(set_id) when is_binary(set_id),
    do: Path.join(proto_sets_dir(), set_id)

  @doc """
  Archivo de estado del store gRPC (colecciones + tabs gRPC). Aparte del
  `state_file/0` de REST — ver decisión N.11.
  """
  @spec grpc_state_file() :: Path.t()
  def grpc_state_file, do: Path.join([data_dir(), "grpc", "state.json"])

  @spec result_dir(protocol(), Date.t()) :: Path.t()
  def result_dir(protocol, %Date{} = date) do
    Path.join([data_dir(), to_string(protocol), Date.to_iso8601(date)])
  end

  @doc """
  Construye el path de un archivo de resultado por ejecución.

  `epoch_ms` toma el valor por defecto `System.os_time(:millisecond)` al
  momento de llamar. `ext` es la extensión del archivo sin el punto
  inicial (ej. "json", "txt"). El directorio padre NO se crea — los
  llamadores deben hacer `File.mkdir_p!/1`.
  """
  @spec result_file(protocol(), Date.t(), pos_integer(), String.t()) :: Path.t()
  def result_file(protocol, %Date{} = date, epoch_ms, ext)
      when is_integer(epoch_ms) and is_binary(ext) do
    Path.join(result_dir(protocol, date), "#{epoch_ms}.#{ext}")
  end

  @doc """
  Conveniencia: construye un path para "ahora" (fecha UTC, epoch ms
  actual), eligiendo la extensión desde el header Content-Type de la
  respuesta.
  """
  @spec result_file_now(protocol(), String.t() | nil) :: Path.t()
  def result_file_now(protocol, content_type) do
    result_file(protocol, Date.utc_today(), now_epoch_ms(), extension_for(content_type))
  end

  @spec now_epoch_ms() :: integer()
  def now_epoch_ms, do: System.os_time(:millisecond)

  @doc """
  Mapea un valor de header Content-Type a una extensión de archivo
  sensata. Hace fallback a "bin" para tipos desconocidos o ausentes.
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
