defmodule TestFlowPhx.UseCases.Grpc.ProtoLoaderTest do
  # async: false — el cache vive en :persistent_term (global).
  use ExUnit.Case, async: false

  alias TestFlowPhx.UseCases.Grpc.ProtoLoader
  alias TestFlowPhx.Infrastructure.Grpc.WireCodec

  @simple """
  syntax = "proto3";
  package svc;
  enum Color { UNKNOWN = 0; RED = 1; }
  message Req { string q = 1; int32 n = 2; }
  message Resp { string a = 1; Color color = 2; map<string,int32> counts = 3; }
  service Greeter {
    rpc Unary(Req) returns (Resp);
    rpc Down(Req) returns (stream Resp);
  }
  """

  setup do
    ProtoLoader.clear_cache()
    dir = Path.join(System.tmp_dir!(), "tf_proto_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    write = fn name, content ->
      path = Path.join(dir, name)
      File.write!(path, content)
      path
    end

    %{dir: dir, write: write}
  end

  describe "load/2 — extracción" do
    test "services y methods (server streaming detectado)", %{write: write} do
      {:ok, d} = ProtoLoader.load([write.("svc.proto", @simple)])

      assert [%{name: "svc.Greeter", methods: methods}] = d.services
      by_name = Map.new(methods, &{&1.name, &1})

      assert by_name["Unary"].input_type == ".svc.Req"
      assert by_name["Unary"].output_type == ".svc.Resp"
      refute by_name["Unary"].server_streaming?
      assert by_name["Down"].server_streaming?
    end

    test "messages_by_name incluye mensajes, enums y el entry del map", %{write: write} do
      {:ok, d} = ProtoLoader.load([write.("svc.proto", @simple)])

      assert Map.has_key?(d.messages_by_name, ".svc.Req")
      assert Map.has_key?(d.messages_by_name, ".svc.Resp")
      # entry sintético del map<string,int32> counts
      assert Map.has_key?(d.messages_by_name, ".svc.Resp.CountsEntry")
      assert Map.has_key?(d.enums_by_name, ".svc.Color")
      assert [%{package: "svc"}] = d.files
    end

    test "el registry resultante alimenta directo a WireCodec (round-trip)", %{write: write} do
      {:ok, d} = ProtoLoader.load([write.("svc.proto", @simple)])
      resp = d.messages_by_name[".svc.Resp"]
      value = %{"a" => "hola", "color" => 1, "counts" => %{"x" => 9}}

      bytes = WireCodec.encode(resp, value, d.messages_by_name)
      assert WireCodec.decode(resp, bytes, d.messages_by_name) == value
    end
  end

  describe "load/2 — cache" do
    test "segunda carga con mismo contenido es cache hit (no corre protoc)", %{write: write} do
      path = write.("svc.proto", @simple)
      {:ok, _} = ProtoLoader.load([path])

      boom = fn _ -> raise "protoc no debería correr en un cache hit" end
      assert {:ok, d2} = ProtoLoader.load([path], protoc_runner: boom)
      assert Map.has_key?(d2.messages_by_name, ".svc.Req")
    end

    test "cambiar el contenido invalida el cache", %{write: write} do
      path = write.("svc.proto", @simple)
      {:ok, _} = ProtoLoader.load([path])

      File.write!(path, @simple <> "\nmessage Extra { int32 z = 1; }\n")
      boom = fn _ -> raise "cache miss esperado: el contenido cambió" end

      assert_raise RuntimeError, fn -> ProtoLoader.load([path], protoc_runner: boom) end
    end

    test "cache: false ignora el cache", %{write: write} do
      path = write.("svc.proto", @simple)
      {:ok, _} = ProtoLoader.load([path])
      boom = fn _ -> raise "cache deshabilitado, debería correr el runner" end
      assert_raise RuntimeError, fn -> ProtoLoader.load([path], cache: false, protoc_runner: boom) end
    end
  end

  describe "load/2 — import_paths (raíz de imports estilo paquete)" do
    # main.proto vive en deep/ e importa "shared/dep.proto" relativo a la raíz
    # `dir`, no a su propio directorio. Sin import_paths el include es dirname
    # (deep/) y protoc no encuentra el import; con import_paths: [dir] sí.
    setup %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "deep"))
      File.mkdir_p!(Path.join(dir, "shared"))

      File.write!(Path.join(dir, "shared/dep.proto"), """
      syntax = "proto3";
      package dep;
      message Dep { string x = 1; }
      """)

      main = Path.join(dir, "deep/main.proto")

      File.write!(main, """
      syntax = "proto3";
      package main;
      import "shared/dep.proto";
      message Main { dep.Dep d = 1; }
      service S { rpc Call(Main) returns (Main); }
      """)

      %{main: main}
    end

    test "sin import_paths el import no resuelve", %{main: main} do
      assert {:error, msg} = ProtoLoader.load([main])
      assert msg =~ "shared/dep.proto"
    end

    test "con import_paths: [raíz] resuelve y carga", %{main: main, dir: dir} do
      assert {:ok, d} = ProtoLoader.load([main], import_paths: [dir])
      assert [%{name: "main.S"}] = d.services
      assert Map.has_key?(d.messages_by_name, ".main.Main")
      assert Map.has_key?(d.messages_by_name, ".dep.Dep")
    end

    test "el cache distingue import_paths distintos", %{main: main, dir: dir} do
      assert {:ok, _} = ProtoLoader.load([main], import_paths: [dir])
      # mismo contenido pero sin import_paths: NO debe pegar el cache anterior
      # (de lo contrario devolvería el descriptor cacheado en vez de fallar).
      assert {:error, _} = ProtoLoader.load([main])
    end
  end

  describe "load/2 — errores" do
    test "archivo inexistente", %{dir: dir} do
      assert {:error, msg} = ProtoLoader.load([Path.join(dir, "nope.proto")])
      assert msg =~ "no encontrado"
    end

    test "lista vacía" do
      assert {:error, msg} = ProtoLoader.load([])
      assert msg =~ "no se especificaron"
    end

    test "proto inválido devuelve error legible de protoc", %{write: write} do
      path = write.("bad.proto", "syntax = \"proto3\";\nmessage X { int32 ; }\n")
      assert {:error, msg} = ProtoLoader.load([path])
      assert is_binary(msg) and msg != ""
      assert msg =~ "bad.proto"
    end
  end

  describe "format_error/1" do
    test "pista de optional/proto3" do
      out = "foo.proto:3:5: Explicit 'optional' labels are disallowed in the Proto3 syntax."
      assert ProtoLoader.format_error(out) =~ "protoc 3.15+"
    end
  end
end
