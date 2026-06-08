defmodule TestFlowPhx.UseCases.ExtractionTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.UseCases.Extraction

  describe "get/2" do
    test "extrae una clave de primer nivel" do
      assert Extraction.get(%{"token" => "abc"}, "token") == {:ok, "abc"}
    end

    test "extrae una clave anidada (dot-path)" do
      data = %{"cuerpo" => %{"sesion" => %{"token" => "xyz"}}}
      assert Extraction.get(data, "cuerpo.sesion.token") == {:ok, "xyz"}
    end

    test "indexa listas con un segmento numérico" do
      data = %{"mensajes" => [%{"id" => "a"}, %{"id" => "b"}]}
      assert Extraction.get(data, "mensajes.1.id") == {:ok, "b"}
    end

    test ":error si una clave no existe" do
      assert Extraction.get(%{"a" => 1}, "b") == :error
      assert Extraction.get(%{"a" => %{"b" => 1}}, "a.c") == :error
    end

    test ":error si se indexa algo que no es lista/map o fuera de rango" do
      assert Extraction.get(%{"a" => "x"}, "a.b") == :error
      assert Extraction.get(%{"a" => [1]}, "a.5") == :error
    end

    test ":error con path vacío o no-string" do
      assert Extraction.get(%{"a" => 1}, "") == :error
      assert Extraction.get(%{"a" => 1}, nil) == :error
    end
  end

  describe "to_value/1" do
    test "strings tal cual; números/bool a texto; nil a vacío" do
      assert Extraction.to_value("hola") == "hola"
      assert Extraction.to_value(42) == "42"
      assert Extraction.to_value(true) == "true"
      assert Extraction.to_value(nil) == ""
    end

    test "map/list se serializan a JSON" do
      assert Extraction.to_value(%{"a" => 1}) == ~s({"a":1})
      assert Extraction.to_value([1, 2]) == "[1,2]"
    end
  end
end
