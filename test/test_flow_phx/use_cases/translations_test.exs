defmodule TestFlowPhx.UseCases.TranslationsTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.UseCases.Translations

  test "available_locales/0 incluye en y es-MX" do
    locales = Translations.available_locales()
    assert "en" in locales
    assert "es-MX" in locales
  end

  test "default_locale/0 es es-MX" do
    assert Translations.default_locale() == "es-MX"
  end

  test "t/3 resuelve una llave anidada" do
    assert Translations.t("es-MX", "sidebar.collections_tab") == "Colecciones"
    assert Translations.t("en", "sidebar.collections_tab") == "Collections"
  end

  test "t/3 hace fallback al locale default si la llave no existe en el pedido" do
    # Fingimos una llave que sólo existe en es-MX dejando que el "en"
    # use la misma — para este test usamos una que existe en ambos.
    # Mejor: pasar un locale inexistente y verificar el fallback al default.
    assert Translations.t("xx-XX", "sidebar.collections_tab") == "Colecciones"
  end

  test "t/3 devuelve la llave si no se encuentra en ningún locale" do
    assert Translations.t("es-MX", "no.existe.esta.llave") == "no.existe.esta.llave"
  end

  test "t/3 interpola variables %{...}" do
    result = Translations.t("es-MX", "flashes.imported_many", count: 5)
    assert result == "Importadas 5 colecciones."
  end
end
