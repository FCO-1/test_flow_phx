defmodule TestFlowPhx.Infrastructure.Grpc.FrameTest do
  use ExUnit.Case, async: true

  alias TestFlowPhx.Infrastructure.Grpc.Frame

  test "encode: flag 0 + longitud big-endian + payload" do
    assert Frame.encode(<<0xAB, 0xCD>>) == <<0, 0, 0, 0, 2, 0xAB, 0xCD>>
    assert Frame.encode("") == <<0, 0, 0, 0, 0>>
  end

  test "decode: un frame completo" do
    assert Frame.decode(Frame.encode("hi")) == {["hi"], ""}
  end

  test "decode: varios frames concatenados" do
    buf = Frame.encode("a") <> Frame.encode("bb") <> Frame.encode("ccc")
    assert Frame.decode(buf) == {["a", "bb", "ccc"], ""}
  end

  test "decode: frame parcial queda como resto" do
    full = Frame.encode("hello")
    {head, tail} = String.split_at(full, 7)
    # header (5) + 2 de payload → frame incompleto, sin payloads
    assert Frame.decode(head) == {[], head}
    # completar con el resto reconstruye el frame
    assert {["hello"], ""} = Frame.decode(head <> tail)
  end

  test "decode: header incompleto (< 5 bytes) queda como resto" do
    assert Frame.decode(<<0, 0, 0>>) == {[], <<0, 0, 0>>}
  end

  test "decode: frame completo + cola parcial" do
    buf = Frame.encode("x") <> <<0, 0, 0, 0, 9, "parci">>
    assert {["x"], <<0, 0, 0, 0, 9, "parci">>} = Frame.decode(buf)
  end

  test "encode/decode round-trip de payloads binarios arbitrarios" do
    payloads = [<<0, 1, 2, 255>>, "", "proto-bytes", :crypto.strong_rand_bytes(300)]
    buf = payloads |> Enum.map(&Frame.encode/1) |> IO.iodata_to_binary()
    assert {^payloads, ""} = Frame.decode(buf)
  end

  test "decode: frame comprimido levanta" do
    assert_raise ArgumentError, ~r/comprimido/, fn ->
      Frame.decode(<<1::8, 0::32>>)
    end
  end
end
