defmodule TestFlowPhx.UseCases.Grpc.GrpcProtoSets do
  @moduledoc """
  Gestiona los **proto-sets**: bundles de `.proto` (el árbol completo, con sus
  imports) guardados bajo `data/grpc/proto_sets/<id>/`. El directorio del set ES
  el `import_root`.

  ## Crear desde un `.zip` (`create_from_zip/2`)

  El flujo, pensado para que "just works" aunque el zip venga con una carpeta
  envolvente:

    1. **Descomprime** en memoria y se queda solo con los `.proto` (descarta
       entradas con `..` o rutas absolutas — anti path-traversal).
    2. **Autodetecta el import root** (reestructuración): parsea los
       `import "..."` de cada `.proto` y busca el prefijo de directorio que hay
       que *quitar* para que **todos** los imports resuelvan. Así un zip
       `export/donavida/...` se normaliza a `donavida/...` y el root queda limpio.
    3. **Valida con protoc** (vía `ProtoLoader`): si falta un import o un
       `.proto` no compila, devuelve el error legible de protoc en vez de
       guardar un set roto.
    4. **Almacena** el árbol normalizado + un `_manifest.json`.

  Si los imports no resuelven bajo ningún prefijo, devuelve `{:error, msg}`
  listando los imports faltantes (el zip está incompleto o mal armado).

  ## Crear desde un solo `.proto` (`create_from_file/3`)

  Un `.proto` autocontenido (sin imports, como el flujo actual) se guarda como
  un proto-set de un archivo. Si ese `.proto` importa otros, protoc fallará y se
  devuelve un error pidiendo subir el set completo como `.zip`.

  ## Resolución para el motor (`resolve_paths/2`)

  Dado un set + un `entry_file` (relativo), devuelve `{proto_paths, import_paths}`
  listos para `ProtoLoader`/`GrpcExecutor`. Rutas con `/` (Windows-friendly).

  Datos en disco = fuente de verdad: `list/0`/`get/1` escanean el directorio.
  """

  alias TestFlowPhx.Domain.Grpc.ProtoSet
  alias TestFlowPhx.Infrastructure.Storage.Paths
  alias TestFlowPhx.UseCases.Grpc.ProtoLoader

  @manifest "_manifest.json"
  @import_re ~r/^\s*import\s+(?:public\s+|weak\s+)?"([^"]+)"\s*;/m
  @service_re ~r/^\s*service\s+\w+/m

  # ── creación ─────────────────────────────────────────────────────────────────

  @doc """
  Crea un proto-set desde el binario de un `.zip`. Opts: `name` (default
  derivado del árbol), `now` (epoch ms, inyectable para tests).
  """
  @spec create_from_zip(binary(), keyword()) :: {:ok, ProtoSet.t()} | {:error, String.t()}
  def create_from_zip(zip_binary, opts \\ []) when is_binary(zip_binary) do
    with {:ok, files} <- unzip(zip_binary),
         {:ok, files} <- ensure_nonempty(files),
         {:ok, prefix} <- detect_prefix(files) do
      normalized = strip_prefix(files, prefix)
      name = opts[:name] || default_name(normalized)
      validate_and_store(normalized, name, opts[:now])
    end
  end

  @doc """
  Crea un proto-set desde un único `.proto` (contenido + nombre de archivo).
  Opts: `name`, `now`.
  """
  @spec create_from_file(binary(), String.t(), keyword()) ::
          {:ok, ProtoSet.t()} | {:error, String.t()}
  def create_from_file(content, filename, opts \\ []) when is_binary(content) do
    rel = Path.basename(filename)
    name = opts[:name] || drop_ext(rel)
    validate_and_store([{rel, content}], name, opts[:now])
  end

  # ── consulta ─────────────────────────────────────────────────────────────────

  @spec list() :: [ProtoSet.t()]
  def list do
    dir = Paths.proto_sets_dir()

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&load_manifest/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(&(&1.created_ms || 0))

      {:error, _} ->
        []
    end
  end

  @spec get(String.t()) :: ProtoSet.t() | nil
  def get(id) when is_binary(id) do
    dir = Paths.proto_set_dir(id)
    if File.dir?(dir), do: load_manifest(dir), else: nil
  end

  @doc "Busca un set por su `name` (lo que viaja en el export). Devuelve el primero."
  @spec get_by_name(String.t()) :: ProtoSet.t() | nil
  def get_by_name(name) when is_binary(name) do
    Enum.find(list(), &(&1.name == name))
  end

  @spec delete(String.t()) :: :ok
  def delete(id) when is_binary(id) do
    File.rm_rf(Paths.proto_set_dir(id))
    :ok
  end

  @doc """
  Resuelve `{proto_paths, import_paths}` para cargar `entry_file` de este set.
  """
  @spec resolve_paths(ProtoSet.t() | String.t(), String.t()) :: {[String.t()], [String.t()]}
  def resolve_paths(%ProtoSet{id: id}, entry_file), do: resolve_paths(id, entry_file)

  def resolve_paths(id, entry_file) when is_binary(id) do
    root = fwd(Paths.proto_set_dir(id))
    {[root <> "/" <> entry_file], [root]}
  end

  # ── interno: zip ─────────────────────────────────────────────────────────────

  defp unzip(zip_binary) do
    case :zip.unzip(zip_binary, [:memory]) do
      {:ok, entries} ->
        files =
          entries
          |> Enum.map(fn {name, content} -> {normalize_entry(name), content} end)
          |> Enum.filter(fn {name, _} -> is_binary(name) and String.ends_with?(name, ".proto") end)

        {:ok, files}

      {:error, reason} ->
        {:error, "no se pudo descomprimir el zip: #{inspect(reason)}"}
    end
  end

  # Normaliza el nombre de una entrada y descarta rutas peligrosas (absolutas o
  # con `..`). Devuelve nil para entradas a descartar.
  defp normalize_entry(name) do
    s = name |> to_string() |> String.replace("\\", "/") |> String.trim_leading("/")

    cond do
      s == "" -> nil
      Path.type(s) == :absolute -> nil
      Enum.any?(Path.split(s), &(&1 == "..")) -> nil
      true -> s
    end
  end

  defp ensure_nonempty([]), do: {:error, "el zip no contiene archivos .proto"}
  defp ensure_nonempty(files), do: {:ok, files}

  # ── interno: detección del import root (reestructuración) ─────────────────────

  defp detect_prefix(files) do
    imports = files |> Enum.flat_map(fn {_p, c} -> parse_imports(c) end) |> Enum.uniq()

    if imports == [] do
      {:ok, ""}
    else
      pathset = MapSet.new(files, fn {p, _} -> p end)
      candidates = prefix_candidates(files, imports)

      case Enum.find(candidates, fn pre ->
             Enum.all?(imports, &MapSet.member?(pathset, pre <> &1))
           end) do
        nil ->
          unresolved =
            Enum.reject(imports, fn imp ->
              Enum.any?(candidates, &MapSet.member?(pathset, &1 <> imp))
            end)

          {:error,
           "el zip está incompleto o mal estructurado: no se resolvieron estos " <>
             "imports: #{Enum.join(unresolved, ", ")}"}

        prefix ->
          {:ok, prefix}
      end
    end
  end

  # Prefijos candidatos a quitar: "" y, por cada archivo que termina con un
  # import, el tramo de directorio anterior (debe cerrar en "/").
  defp prefix_candidates(files, imports) do
    for({p, _} <- files, imp <- imports, String.ends_with?(p, imp), do: chop(p, imp))
    |> Enum.filter(fn pre -> pre == "" or String.ends_with?(pre, "/") end)
    |> then(&["" | &1])
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1)
  end

  defp chop(path, suffix), do: binary_part(path, 0, byte_size(path) - byte_size(suffix))

  defp parse_imports(content) do
    @import_re |> Regex.scan(content) |> Enum.map(fn [_, p] -> p end)
  end

  defp strip_prefix(files, ""), do: files

  defp strip_prefix(files, prefix) do
    files
    |> Enum.filter(fn {p, _} -> String.starts_with?(p, prefix) end)
    |> Enum.map(fn {p, c} ->
      {binary_part(p, byte_size(prefix), byte_size(p) - byte_size(prefix)), c}
    end)
  end

  # ── interno: validar + almacenar ─────────────────────────────────────────────

  defp validate_and_store(files, name, now) do
    id = ProtoSet.new_id()
    root = Paths.proto_set_dir(id)
    write_tree!(root, files)

    all_rel = files |> Enum.map(&elem(&1, 0)) |> Enum.sort()

    case validate(root, validation_roots(files, all_rel)) do
      :ok ->
        set = %ProtoSet{
          id: id,
          name: name,
          entry_files: entry_files(files),
          files: all_rel,
          created_ms: now || Paths.now_epoch_ms()
        }

        File.write!(Path.join(root, @manifest), Jason.encode!(manifest_map(set), pretty: true))
        {:ok, set}

      {:error, msg} ->
        File.rm_rf(root)
        {:error, msg}
    end
  end

  defp write_tree!(root, files) do
    Enum.each(files, fn {rel, content} ->
      abs = Path.join(root, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, content)
    end)
  end

  # Archivos a pasar como args a protoc: los que NO son importados por ningún
  # otro del set (`--include_imports` jala el resto). Pasar un archivo que además
  # es importado lo definiría dos veces ("already defined"). Si todos están
  # importados (ciclo), cae a pasar todos.
  defp validation_roots(files, all_rel) do
    imported = files |> Enum.flat_map(fn {_p, c} -> parse_imports(c) end) |> MapSet.new()

    case Enum.reject(all_rel, &MapSet.member?(imported, &1)) do
      [] -> all_rel
      roots -> roots
    end
  end

  # Valida con protoc (vía ProtoLoader): compila los roots con el dir del set
  # como import path; si falta un import o un .proto no compila, devuelve el error.
  defp validate(root, roots) do
    paths = Enum.map(roots, &fwd(Path.join(root, &1)))

    case ProtoLoader.load(paths, import_paths: [fwd(root)], cache: false) do
      {:ok, _desc} -> :ok
      {:error, msg} -> {:error, msg}
    end
  end

  defp entry_files(files) do
    for({rel, content} <- files, Regex.match?(@service_re, content), do: rel) |> Enum.sort()
  end

  # ── interno: manifest / helpers ──────────────────────────────────────────────

  defp load_manifest(set_dir) do
    file = Path.join(set_dir, @manifest)

    with {:ok, raw} <- File.read(file),
         {:ok, map} <- Jason.decode(raw) do
      %ProtoSet{
        id: Path.basename(set_dir),
        name: map["name"] || Path.basename(set_dir),
        entry_files: string_list(map["entry_files"]),
        files: string_list(map["files"]),
        created_ms: map["created_ms"]
      }
    else
      _ -> nil
    end
  end

  defp manifest_map(%ProtoSet{} = s) do
    %{
      "name" => s.name,
      "entry_files" => s.entry_files,
      "files" => s.files,
      "created_ms" => s.created_ms
    }
  end

  defp default_name(files) do
    tops = files |> Enum.map(fn {p, _} -> p |> Path.split() |> List.first() end) |> Enum.uniq()

    case tops do
      [single] when is_binary(single) ->
        if String.ends_with?(single, ".proto"), do: drop_ext(single), else: single

      _ ->
        "proto-set"
    end
  end

  defp drop_ext(name), do: Path.rootname(Path.basename(name))

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_), do: []

  defp fwd(path), do: String.replace(path, "\\", "/")
end
