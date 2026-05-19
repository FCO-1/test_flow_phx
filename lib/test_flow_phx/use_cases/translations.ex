defmodule TestFlowPhx.UseCases.Translations do
  @moduledoc """
  i18n simple compilado: carga los archivos JSON de `priv/locales/` en
  compile-time y expone `t/3` para resolver llaves anidadas con notación
  de punto (`"sidebar.collections_tab"`).

  Por qué no Gettext: para 2 idiomas con strings cortos, mantener
  archivos JSON editables a mano es más simple. Cuando el set de
  strings crezca, Gettext con `.po` puede ser la mejor opción.
  """

  @locales_dir Path.join([:code.priv_dir(:test_flow_phx), "locales"])

  @default_locale "es-MX"

  # Cargamos cada archivo en compile-time y declaramos `@external_resource`
  # para que mix re-compile cuando los archivos cambien.
  @translations (for file <- Path.wildcard(Path.join(@locales_dir, "*.json")), into: %{} do
                   locale = Path.basename(file, ".json")
                   {locale, file |> File.read!() |> Jason.decode!()}
                 end)

  for file <- Path.wildcard(Path.join(@locales_dir, "*.json")) do
    @external_resource file
  end

  @doc "Locales disponibles, ordenados alfabéticamente."
  @spec available_locales() :: [String.t()]
  def available_locales, do: @translations |> Map.keys() |> Enum.sort()

  @doc "Locale por defecto cuando el usuario no ha elegido nada."
  @spec default_locale() :: String.t()
  def default_locale, do: @default_locale

  @doc """
  Resuelve una llave de traducción.

  La llave usa notación de punto:
      t("es-MX", "sidebar.collections_tab")  #=> "Colecciones"

  Si el locale no existe o la llave no se encuentra, hace fallback al
  locale default. Si tampoco está ahí, devuelve la llave original — así
  fallos silenciosos son visibles en la UI.

  Soporta interpolación tipo `%{name}`:
      t("es-MX", "flashes.imported_many", count: 3)
  """
  @spec t(String.t(), String.t(), keyword()) :: String.t()
  def t(locale, key, opts \\ []) when is_binary(key) do
    value =
      lookup(@translations[locale], key) ||
        lookup(@translations[@default_locale], key) ||
        key

    interpolate(value, opts)
  end

  defp lookup(nil, _key), do: nil

  defp lookup(map, key) when is_map(map) and is_binary(key) do
    key
    |> String.split(".")
    |> Enum.reduce_while(map, fn segment, acc ->
      case acc do
        m when is_map(m) ->
          case Map.fetch(m, segment) do
            {:ok, v} -> {:cont, v}
            :error -> {:halt, nil}
          end

        _ ->
          {:halt, nil}
      end
    end)
    |> case do
      v when is_binary(v) -> v
      _ -> nil
    end
  end

  defp interpolate(value, []) when is_binary(value), do: value

  defp interpolate(value, opts) when is_binary(value) do
    Enum.reduce(opts, value, fn {key, val}, acc ->
      String.replace(acc, "%{#{key}}", to_string(val))
    end)
  end
end
