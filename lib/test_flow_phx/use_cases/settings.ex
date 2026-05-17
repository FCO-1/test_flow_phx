defmodule TestFlowPhx.UseCases.Settings do
  @moduledoc """
  Configuración de la app visible al usuario, persistida en una
  ubicación estable del SO.

  NO puede vivir dentro de `data/state.json` porque el directorio de
  datos es justamente una de las configuraciones — bootstrapping
  circular. Por defecto:
  `$XDG_CONFIG_HOME/test_flow_phx/config.json`, con fallback a
  `~/.config/test_flow_phx/config.json`. Override vía la variable de
  entorno `TEST_FLOW_CONFIG_FILE` (útil para tests aislados).
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
  Lee la configuración persistida, aplicando defaults para llaves
  ausentes.

  Devuelve un mapa con llaves string (`"data_dir"`) — nunca crashea si
  el archivo no existe o está malformado.
  """
  @spec get() :: %{String.t() => term()}
  def get do
    case read_file() do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc "Directorio de datos efectivo en este momento (override > env > default)."
  @spec get_data_dir() :: Path.t()
  def get_data_dir, do: Paths.data_dir()

  @doc """
  Directorio de datos por defecto — lo que la app usaría si el usuario
  no ha configurado nada. Útil para mostrar en la UI de Settings.
  """
  @spec default_data_dir() :: Path.t()
  def default_data_dir, do: Paths.default_data_dir()

  @doc """
  Configura el directorio de datos. Valida permisos de filesystem,
  persiste el setting a disco, cambia `Paths.data_dir/0` al nuevo valor
  y hace hot-swap del JsonFileRepo para que escriba en la nueva
  ubicación.
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
  Lee el directorio de datos configurado desde disco (sin fallback al
  default). La usa `Application.start/2` para aplicar la elección del
  usuario antes de que el repo arranque.
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
  Explicación legible para humanos de un error de `validate_dir/1`.
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
