defmodule TestFlowPhx.UseCases.Settings do
  @moduledoc """
  User-facing app settings persisted at a stable OS location.

  We can NOT keep these in `data/state.json` because the data dir itself
  is one of the settings — chicken-and-egg. Defaults to
  `$XDG_CONFIG_HOME/test_flow_phx/config.json`, falling back to
  `~/.config/test_flow_phx/config.json`. Override via `TEST_FLOW_CONFIG_FILE`.
  """

  alias TestFlowPhx.Infrastructure.Storage.{JsonFileRepo, Paths}

  @type validate_error ::
          :empty_path
          | :not_writable
          | :not_readable
          | {:not_a_directory, atom()}
          | {:cannot_create, atom()}
          | {:stat_failed, atom()}

  @doc """
  Reads the persisted settings, applying defaults for missing keys.

  Returns a map of string keys (`"data_dir"`) — never crashes if the file
  is missing or malformed.
  """
  @spec get() :: %{String.t() => term()}
  def get do
    case read_file() do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Currently-effective data dir (settings override > env > default)."
  @spec get_data_dir() :: Path.t()
  def get_data_dir, do: Paths.data_dir()

  @doc """
  Default data dir — what the app would use if the user has not set
  anything. Useful to surface in the settings UI.
  """
  @spec default_data_dir() :: Path.t()
  def default_data_dir, do: Paths.default_data_dir()

  @doc """
  Set the data dir. Validates filesystem permissions, persists the
  setting to disk, switches `Paths.data_dir/0` to the new value, and
  swaps the running JsonFileRepo to write to the new location.
  """
  @spec set_data_dir(String.t()) ::
          {:ok, Path.t()} | {:error, validate_error()}
  def set_data_dir(input) when is_binary(input) do
    with {:ok, expanded} <- expand(input),
         :ok <- validate_dir(expanded),
         :ok <- write_setting("data_dir", expanded),
         :ok <- apply_data_dir(expanded) do
      {:ok, expanded}
    end
  end

  @doc """
  Reads the configured data dir from disk (no fallback to default).
  Used by `Application.start/2` to apply the user's choice before the
  repo boots.
  """
  @spec read_persisted_data_dir() :: {:ok, Path.t()} | :error
  def read_persisted_data_dir do
    case get() do
      %{"data_dir" => dir} when is_binary(dir) and dir != "" -> {:ok, dir}
      _ -> :error
    end
  end

  # ----- Validation -----

  @doc false
  @spec validate_dir(Path.t()) :: :ok | {:error, validate_error()}
  def validate_dir(path) when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, access: access}} ->
        check_access(access)

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_a_directory, type}}

      {:error, :enoent} ->
        case File.mkdir_p(path) do
          :ok -> validate_dir(path)
          {:error, posix} -> {:error, {:cannot_create, posix}}
        end

      {:error, posix} ->
        {:error, {:stat_failed, posix}}
    end
  end

  def validate_dir(_), do: {:error, :empty_path}

  defp check_access(:read_write), do: :ok
  defp check_access(:write), do: {:error, :not_readable}
  defp check_access(:read), do: {:error, :not_writable}
  defp check_access(:none), do: {:error, :not_writable}

  defp expand(""), do: {:error, :empty_path}
  defp expand(path) when is_binary(path), do: {:ok, Path.expand(path)}

  # ----- Hot swap -----

  defp apply_data_dir(path) do
    Application.put_env(:test_flow_phx, :data_dir_override, path)
    try_swap_repo(path)
  end

  defp try_swap_repo(path) do
    if Process.whereis(JsonFileRepo) do
      JsonFileRepo.swap_path(Path.join(path, "state.json"))
    else
      :ok
    end
  end

  # ----- Settings file I/O -----

  defp read_file do
    file = config_file()

    case File.read(file) do
      {:ok, body} -> Jason.decode(body)
      {:error, :enoent} -> {:ok, %{}}
      {:error, _} -> {:error, :unreadable}
    end
  end

  defp write_setting(key, value) do
    map = Map.put(get(), key, value)
    file = config_file()

    with :ok <- File.mkdir_p(Path.dirname(file)),
         json = Jason.encode_to_iodata!(map, pretty: true),
         tmp = file <> ".tmp",
         :ok <- File.write(tmp, json),
         :ok <- File.rename(tmp, file) do
      :ok
    else
      {:error, posix} -> {:error, {:cannot_create, posix}}
    end
  end

  defp config_file do
    case System.get_env("TEST_FLOW_CONFIG_FILE") do
      f when is_binary(f) and f != "" ->
        f

      _ ->
        base =
          System.get_env("XDG_CONFIG_HOME")
          |> case do
            nil -> Path.expand("~/.config")
            "" -> Path.expand("~/.config")
            dir -> dir
          end

        Path.join([base, "test_flow_phx", "config.json"])
    end
  end

  @doc """
  Human-friendly explanation for a `validate_dir/1` error.
  """
  @spec format_error(validate_error()) :: String.t()
  def format_error(:empty_path), do: "La ruta está vacía."
  def format_error(:not_writable), do: "El sistema no permite escribir en esa ruta."
  def format_error(:not_readable), do: "El sistema no permite leer esa ruta."

  def format_error({:not_a_directory, type}),
    do: "La ruta apunta a un #{type}, no a un directorio."

  def format_error({:cannot_create, posix}),
    do: "No se pudo crear el directorio (#{posix})."

  def format_error({:stat_failed, posix}),
    do: "No se pudo leer la información del directorio (#{posix})."

  def format_error(other), do: "Error: #{inspect(other)}"
end
