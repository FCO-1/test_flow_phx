defmodule TestFlowPhx.Infrastructure.Grpc.WireCodecTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Infrastructure.Grpc.WireCodec
  alias Google.Protobuf.{DescriptorProto, FieldDescriptorProto, MessageOptions}

  # ── builders de descriptores (sin protoc) ──────────────────────────────────

  defp fdp(name, number, type, opts \\ []) do
    %FieldDescriptorProto{
      name: name,
      number: number,
      type: type,
      label: Keyword.get(opts, :label, :LABEL_OPTIONAL),
      type_name: Keyword.get(opts, :type_name)
    }
  end

  defp msg(name, fields, opts \\ []) do
    options = if opts[:map_entry], do: %MessageOptions{map_entry: true}, else: nil
    %DescriptorProto{name: name, field: fields, options: options}
  end

  # mensaje de un solo campo escalar (número 1) para round-trips puntuales
  defp single(type, opts \\ []), do: msg("M", [fdp("v", 1, type, opts)])

  defp rt(desc, value, registry \\ %{}) do
    bytes = WireCodec.encode(desc, value, registry)
    assert WireCodec.decode(desc, bytes, registry) == value
    bytes
  end

  # ── varint ──────────────────────────────────────────────────────────────────

  describe "varint" do
    test "vectores conocidos" do
      assert WireCodec.encode_varint(0) == <<0x00>>
      assert WireCodec.encode_varint(1) == <<0x01>>
      assert WireCodec.encode_varint(127) == <<0x7F>>
      assert WireCodec.encode_varint(128) == <<0x80, 0x01>>
      assert WireCodec.encode_varint(150) == <<0x96, 0x01>>
      assert WireCodec.encode_varint(300) == <<0xAC, 0x02>>
    end

    test "round-trip incluyendo valores grandes" do
      for n <- [0, 1, 127, 128, 16_383, 16_384, 0xFFFFFFFF, 0xFFFFFFFFFFFFFFFF] do
        assert {^n, ""} = WireCodec.decode_varint(WireCodec.encode_varint(n))
      end
    end

    test "decode deja el resto intacto" do
      assert {150, <<0xFF>>} = WireCodec.decode_varint(<<0x96, 0x01, 0xFF>>)
    end
  end

  describe "zigzag" do
    test "vectores conocidos (32 y 64 bits)" do
      assert WireCodec.zigzag(0, 32) == 0
      assert WireCodec.zigzag(-1, 32) == 1
      assert WireCodec.zigzag(1, 32) == 2
      assert WireCodec.zigzag(-2, 32) == 3
      assert WireCodec.zigzag(2_147_483_647, 32) == 4_294_967_294
      assert WireCodec.zigzag(-2_147_483_648, 32) == 4_294_967_295
      assert WireCodec.zigzag(-1, 64) == 1
    end

    test "round-trip" do
      for n <- [0, -1, 1, -2, 2, 123_456, -123_456, 2_147_483_647, -2_147_483_648] do
        assert WireCodec.unzigzag(WireCodec.zigzag(n, 64)) == n
      end
    end
  end

  describe "tag" do
    test "encode/decode" do
      # field 1, wire type 0 → 0x08
      assert WireCodec.encode_tag(1, 0) == <<0x08>>
      # field 2, wire type 2 → 0x12
      assert WireCodec.encode_tag(2, 2) == <<0x12>>
      assert {6, 2, ""} = WireCodec.decode_tag(WireCodec.encode_tag(6, 2))
    end
  end

  # ── vectores de mensaje conocidos (protobuf.dev/encoding) ───────────────────

  describe "vectores de mensaje conocidos" do
    test "int32 campo 1 = 150 → 08 96 01" do
      assert WireCodec.encode(single(:TYPE_INT32), %{"v" => 150}) == <<0x08, 0x96, 0x01>>
    end

    test "string campo 2 = \"testing\"" do
      desc = msg("M", [fdp("s", 2, :TYPE_STRING)])
      assert WireCodec.encode(desc, %{"s" => "testing"}) == <<0x12, 0x07>> <> "testing"
    end

    test "sint32 campo 1 = -1 (zigzag) → 08 01" do
      assert WireCodec.encode(single(:TYPE_SINT32), %{"v" => -1}) == <<0x08, 0x01>>
    end

    test "repeated int32 packed [3, 270, 86942] campo 6" do
      desc = msg("M", [fdp("d", 6, :TYPE_INT32, label: :LABEL_REPEATED)])
      assert WireCodec.encode(desc, %{"d" => [3, 270, 86_942]}) ==
               <<0x32, 0x06, 0x03, 0x8E, 0x02, 0x9E, 0xA7, 0x05>>
    end
  end

  # ── round-trip por tipo escalar ─────────────────────────────────────────────

  describe "round-trip escalares" do
    test "enteros con signo y sin signo" do
      rt(single(:TYPE_INT32), %{"v" => 42})
      rt(single(:TYPE_INT32), %{"v" => -1})
      rt(single(:TYPE_INT32), %{"v" => -2_147_483_648})
      rt(single(:TYPE_INT64), %{"v" => -9_000_000_000})
      rt(single(:TYPE_UINT32), %{"v" => 4_000_000_000})
      rt(single(:TYPE_UINT64), %{"v" => 0xFFFFFFFFFFFFFFFF})
      rt(single(:TYPE_SINT32), %{"v" => -123_456})
      rt(single(:TYPE_SINT64), %{"v" => -9_000_000_000})
    end

    test "cero explícito se emite y round-trips" do
      assert WireCodec.encode(single(:TYPE_INT32), %{"v" => 0}) == <<0x08, 0x00>>
      rt(single(:TYPE_INT32), %{"v" => 0})
    end

    test "fixed y floats" do
      rt(single(:TYPE_FIXED32), %{"v" => 4_000_000_000})
      rt(single(:TYPE_SFIXED32), %{"v" => -123})
      rt(single(:TYPE_FIXED64), %{"v" => 0xFFFFFFFFFFFFFFFF})
      rt(single(:TYPE_SFIXED64), %{"v" => -9_000_000_000})
      rt(single(:TYPE_FLOAT), %{"v" => 1.5})
      rt(single(:TYPE_FLOAT), %{"v" => -2.25})
      rt(single(:TYPE_DOUBLE), %{"v" => 3.141592653589793})
    end

    test "bool, string, bytes, enum" do
      rt(single(:TYPE_BOOL), %{"v" => true})
      rt(single(:TYPE_BOOL), %{"v" => false})
      rt(single(:TYPE_STRING), %{"v" => "héllo ñ"})
      rt(single(:TYPE_BYTES), %{"v" => <<0, 1, 2, 255>>})
      rt(single(:TYPE_ENUM), %{"v" => 2})
    end

    test "campos ausentes no se emiten" do
      desc = msg("M", [fdp("a", 1, :TYPE_INT32), fdp("b", 2, :TYPE_STRING)])
      assert WireCodec.encode(desc, %{"a" => 7}) == <<0x08, 0x07>>
      assert WireCodec.decode(desc, <<0x08, 0x07>>) == %{"a" => 7}
    end
  end

  # ── mensajes anidados ───────────────────────────────────────────────────────

  describe "mensaje anidado" do
    setup do
      inner = msg("Inner", [fdp("note", 1, :TYPE_STRING)])
      outer = msg("Outer", [fdp("inner", 1, :TYPE_MESSAGE, type_name: ".pkg.Inner")])
      %{registry: %{".pkg.Inner" => inner}, outer: outer}
    end

    test "round-trip", %{outer: outer, registry: reg} do
      rt(outer, %{"inner" => %{"note" => "hi"}}, reg)
    end

    test "submensaje vacío round-trips a mapa vacío", %{outer: outer, registry: reg} do
      rt(outer, %{"inner" => %{}}, reg)
    end
  end

  # ── repeated ─────────────────────────────────────────────────────────────────

  describe "repeated" do
    test "escalar packed round-trip" do
      rt(single(:TYPE_INT32, label: :LABEL_REPEATED) |> with_name("nums"), %{"nums" => [1, 2, 300]})
    end

    test "string repeated (unpacked, un tag por elemento)" do
      desc = msg("M", [fdp("tags", 1, :TYPE_STRING, label: :LABEL_REPEATED)])
      rt(desc, %{"tags" => ["a", "bb", "ccc"]})
    end

    test "mensaje repeated" do
      item = msg("Item", [fdp("n", 1, :TYPE_INT32)])
      desc = msg("M", [fdp("items", 1, :TYPE_MESSAGE, label: :LABEL_REPEATED, type_name: ".pkg.Item")])
      rt(desc, %{"items" => [%{"n" => 1}, %{"n" => 2}]}, %{".pkg.Item" => item})
    end

    test "decode acepta escalares repetidos unpacked (interleaved)" do
      desc = msg("M", [fdp("nums", 1, :TYPE_INT32, label: :LABEL_REPEATED)])
      # tres ocurrencias separadas wire-type 0: 08 01, 08 02, 08 03
      unpacked = <<0x08, 0x01, 0x08, 0x02, 0x08, 0x03>>
      assert WireCodec.decode(desc, unpacked) == %{"nums" => [1, 2, 3]}
    end
  end

  # ── maps ─────────────────────────────────────────────────────────────────────

  describe "map" do
    setup do
      entry =
        msg(
          "CountsEntry",
          [fdp("key", 1, :TYPE_STRING), fdp("value", 2, :TYPE_INT32)],
          map_entry: true
        )

      desc = msg("M", [fdp("counts", 1, :TYPE_MESSAGE, label: :LABEL_REPEATED, type_name: ".pkg.M.CountsEntry")])
      %{desc: desc, registry: %{".pkg.M.CountsEntry" => entry}}
    end

    test "round-trip", %{desc: desc, registry: reg} do
      rt(desc, %{"counts" => %{"a" => 1, "b" => 2}}, reg)
    end

    test "valor cero omitido por el peer se decodifica al default", %{desc: desc, registry: reg} do
      # entry con sólo key="x" (value 0 omitido): para field counts (1, LEN)
      entry = reg[".pkg.M.CountsEntry"]
      blob = WireCodec.encode(entry, %{"key" => "x"})
      wire = WireCodec.encode_tag(1, 2) <> WireCodec.encode_varint(byte_size(blob)) <> blob
      assert WireCodec.decode(desc, wire, reg) == %{"counts" => %{"x" => 0}}
    end
  end

  # ── forward-compat ─────────────────────────────────────────────────────────

  describe "campos desconocidos" do
    test "se descartan sin romper el parseo" do
      desc = msg("M", [fdp("known", 1, :TYPE_INT32)])
      # field 1 = 7, luego field 99 (LEN) con "junk", luego nada
      junk = WireCodec.encode_tag(99, 2) <> WireCodec.encode_varint(4) <> "junk"
      wire = <<0x08, 0x07>> <> junk
      assert WireCodec.decode(desc, wire) == %{"known" => 7}
    end

    test "salta cada wire type" do
      desc = msg("M", [fdp("known", 1, :TYPE_INT32)])
      varint = WireCodec.encode_tag(2, 0) <> WireCodec.encode_varint(999)
      i64 = WireCodec.encode_tag(3, 1) <> <<0::64>>
      i32 = WireCodec.encode_tag(4, 5) <> <<0::32>>
      wire = varint <> i64 <> i32 <> <<0x08, 0x07>>
      assert WireCodec.decode(desc, wire) == %{"known" => 7}
    end
  end

  # helper: renombra el único campo de un single/0 a otro nombre
  defp with_name(%DescriptorProto{field: [f]} = d, name), do: %{d | field: [%{f | name: name}]}
end
