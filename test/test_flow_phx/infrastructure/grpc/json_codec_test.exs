defmodule TestFlowPhx.Infrastructure.Grpc.JsonCodecTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Infrastructure.Grpc.{JsonCodec, WireCodec}

  alias Google.Protobuf.{
    DescriptorProto,
    EnumDescriptorProto,
    EnumValueDescriptorProto,
    FieldDescriptorProto,
    MessageOptions
  }

  # ── descriptores de prueba (Person, con todos los casos espinosos) ──────────

  defp field(name, number, type, opts \\ []) do
    %FieldDescriptorProto{
      name: name,
      number: number,
      type: type,
      label: Keyword.get(opts, :label, :LABEL_OPTIONAL),
      type_name: Keyword.get(opts, :type_name)
    }
  end

  setup do
    pet = %DescriptorProto{name: "Pet", field: [field("kind", 1, :TYPE_STRING)]}

    scores_entry = %DescriptorProto{
      name: "ScoresEntry",
      options: %MessageOptions{map_entry: true},
      field: [field("key", 1, :TYPE_STRING), field("value", 2, :TYPE_INT32)]
    }

    person = %DescriptorProto{
      name: "Person",
      field: [
        field("name", 1, :TYPE_STRING),
        field("age", 2, :TYPE_INT32),
        field("id", 3, :TYPE_INT64),
        field("score", 4, :TYPE_DOUBLE),
        field("color", 5, :TYPE_ENUM, type_name: ".test.Color"),
        field("data", 6, :TYPE_BYTES),
        field("tags", 7, :TYPE_STRING, label: :LABEL_REPEATED),
        field("pet", 8, :TYPE_MESSAGE, type_name: ".test.Pet"),
        field("scores", 9, :TYPE_MESSAGE, type_name: ".test.Person.ScoresEntry", label: :LABEL_REPEATED)
      ]
    }

    color = %EnumDescriptorProto{
      name: "Color",
      value: [
        %EnumValueDescriptorProto{name: "RED", number: 0},
        %EnumValueDescriptorProto{name: "GREEN", number: 1},
        %EnumValueDescriptorProto{name: "BLUE", number: 2}
      ]
    }

    %{
      person: person,
      registry: %{".test.Pet" => pet, ".test.Person.ScoresEntry" => scores_entry, ".test.Person" => person},
      enums: %{".test.Color" => color}
    }
  end

  describe "to_message/4 (JSON → mapa WireCodec)" do
    test "bytes desde base64, enum por nombre, int64 string, float desde entero",
         %{person: p, registry: reg, enums: en} do
      json = %{
        "name" => "ada",
        "age" => 36,
        "id" => "9000000000",
        "score" => 5,
        "color" => "GREEN",
        "data" => Base.encode64("hi")
      }

      assert {:ok, msg} = JsonCodec.to_message(p, json, reg, en)
      assert msg["id"] == 9_000_000_000
      assert msg["score"] === 5.0
      assert msg["color"] == 1
      assert msg["data"] == "hi"
    end

    test "enum por número se acepta tal cual", %{person: p, registry: reg, enums: en} do
      assert {:ok, %{"color" => 2}} = JsonCodec.to_message(p, %{"color" => 2}, reg, en)
    end

    test "anidados, repeated y maps recurren", %{person: p, registry: reg, enums: en} do
      json = %{"tags" => ["a", "b"], "pet" => %{"kind" => "cat"}, "scores" => %{"x" => 1, "y" => 2}}
      assert {:ok, msg} = JsonCodec.to_message(p, json, reg, en)
      assert msg["tags"] == ["a", "b"]
      assert msg["pet"] == %{"kind" => "cat"}
      assert msg["scores"] == %{"x" => 1, "y" => 2}
    end

    test "enum desconocido → {:error, _}", %{person: p, registry: reg, enums: en} do
      assert {:error, msg} = JsonCodec.to_message(p, %{"color" => "MAUVE"}, reg, en)
      assert msg =~ "enum"
    end
  end

  describe "from_message/4 (mapa WireCodec → JSON)" do
    test "bytes a base64 y enum a nombre", %{person: p, registry: reg, enums: en} do
      out = JsonCodec.from_message(p, %{"data" => "hi", "color" => 2}, reg, en)
      assert out["data"] == Base.encode64("hi")
      assert out["color"] == "BLUE"
    end

    test "enum sin descriptor cae al número", %{person: p, registry: reg} do
      out = JsonCodec.from_message(p, %{"color" => 7}, reg, %{})
      assert out["color"] == 7
    end
  end

  describe "round-trip JSON ↔ wire (vía WireCodec)" do
    test "to_message → encode → decode → from_message reconstruye el JSON",
         %{person: p, registry: reg, enums: en} do
      json = %{
        "name" => "ada",
        "age" => 36,
        "id" => "9000000000",
        "color" => "BLUE",
        "data" => Base.encode64(<<1, 2, 3>>),
        "tags" => ["x", "y"],
        "pet" => %{"kind" => "dog"},
        "scores" => %{"a" => 10}
      }

      {:ok, msg} = JsonCodec.to_message(p, json, reg, en)
      wire = WireCodec.encode(p, msg, reg)
      back = WireCodec.decode(p, wire, reg)
      out = JsonCodec.from_message(p, back, reg, en)

      # los campos presentes vuelven idénticos (int64 sigue como número tras el viaje)
      assert out["name"] == "ada"
      assert out["age"] == 36
      assert out["id"] == 9_000_000_000
      assert out["color"] == "BLUE"
      assert out["data"] == Base.encode64(<<1, 2, 3>>)
      assert out["tags"] == ["x", "y"]
      assert out["pet"] == %{"kind" => "dog"}
      assert out["scores"] == %{"a" => 10}
    end
  end
end
