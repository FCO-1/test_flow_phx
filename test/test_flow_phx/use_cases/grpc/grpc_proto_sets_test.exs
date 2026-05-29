defmodule TestFlowPhx.UseCases.Grpc.GrpcProtoSetsTest do
  # async: false — opera sobre el directorio compartido data/grpc/proto_sets.
  use ExUnit.Case, async: false

  alias TestFlowPhx.UseCases.Grpc.GrpcProtoSets
  alias TestFlowPhx.Infrastructure.Storage.Paths

  @dep """
  syntax = "proto3";
  package donavida.comun.v1;
  message C { string x = 1; }
  """

  @auth """
  syntax = "proto3";
  package donavida.auth.v1;
  import "donavida/comun/v1/c.proto";
  message Req { donavida.comun.v1.C c = 1; }
  message Resp { string ok = 1; }
  service Svc { rpc Call(Req) returns (Resp); }
  """

  @solo """
  syntax = "proto3";
  package solo;
  message R { string a = 1; }
  service S { rpc U(R) returns (R); }
  """

  setup do
    File.rm_rf(Paths.proto_sets_dir())
    on_exit(fn -> File.rm_rf(Paths.proto_sets_dir()) end)
    :ok
  end

  defp zip(files) do
    entries = Enum.map(files, fn {name, content} -> {String.to_charlist(name), content} end)
    {:ok, {_name, bin}} = :zip.create(~c"set.zip", entries, [:memory])
    bin
  end

  describe "create_from_zip/2 — árbol con imports" do
    test "carga un árbol bien estructurado y detecta el entry con service" do
      bin =
        zip([
          {"donavida/auth/v1/auth.proto", @auth},
          {"donavida/comun/v1/c.proto", @dep}
        ])

      assert {:ok, set} = GrpcProtoSets.create_from_zip(bin)
      assert set.entry_files == ["donavida/auth/v1/auth.proto"]
      assert "donavida/comun/v1/c.proto" in set.files
      assert set.name == "donavida"
      assert is_integer(set.created_ms)
    end

    test "reestructura: quita la carpeta envolvente del zip" do
      bin =
        zip([
          {"export-2024/donavida/auth/v1/auth.proto", @auth},
          {"export-2024/donavida/comun/v1/c.proto", @dep}
        ])

      assert {:ok, set} = GrpcProtoSets.create_from_zip(bin)
      # el prefijo "export-2024/" se quitó → el árbol queda normalizado
      assert set.entry_files == ["donavida/auth/v1/auth.proto"]
      assert Enum.sort(set.files) ==
               ["donavida/auth/v1/auth.proto", "donavida/comun/v1/c.proto"]

      # y en disco el import_root resuelve
      {protos, [root]} = GrpcProtoSets.resolve_paths(set, "donavida/auth/v1/auth.proto")
      assert File.exists?(hd(protos))
      assert File.dir?(root)
    end

    test "zip incompleto: import que no resuelve → error claro, sin dejar set" do
      bin = zip([{"donavida/auth/v1/auth.proto", @auth}])

      assert {:error, msg} = GrpcProtoSets.create_from_zip(bin)
      assert msg =~ "donavida/comun/v1/c.proto"
      assert GrpcProtoSets.list() == []
    end

    test "proto inválido: protoc rechaza → error, con rollback (no queda set)" do
      bad = "syntax = \"proto3\";\nmessage X { int32 ; }\n"
      bin = zip([{"bad.proto", bad}])

      assert {:error, msg} = GrpcProtoSets.create_from_zip(bin)
      assert is_binary(msg) and msg != ""
      assert GrpcProtoSets.list() == []
    end

    test "ignora archivos que no son .proto (README, etc.)" do
      bin =
        zip([
          {"solo.proto", @solo},
          {"README.md", "# notas"},
          {"buf.yaml", "version: v1"}
        ])

      assert {:ok, set} = GrpcProtoSets.create_from_zip(bin)
      assert set.files == ["solo.proto"]
    end
  end

  describe "create_from_file/3 — un solo .proto (flujo simple)" do
    test "guarda un proto autocontenido como set de un archivo" do
      assert {:ok, set} = GrpcProtoSets.create_from_file(@solo, "solo.proto")
      assert set.files == ["solo.proto"]
      assert set.entry_files == ["solo.proto"]
      assert set.name == "solo"
    end

    test "un .proto que importa otro (subido suelto) falla pidiendo el set completo" do
      assert {:error, msg} = GrpcProtoSets.create_from_file(@auth, "auth.proto")
      assert msg =~ "c.proto"
    end
  end

  describe "list/get/delete" do
    test "lista, obtiene por id y por nombre, y borra" do
      {:ok, a} = GrpcProtoSets.create_from_file(@solo, "solo.proto", name: "alpha")

      assert [listed] = GrpcProtoSets.list()
      assert listed.id == a.id
      assert GrpcProtoSets.get(a.id).name == "alpha"
      assert GrpcProtoSets.get_by_name("alpha").id == a.id
      assert GrpcProtoSets.get("noexiste") == nil

      assert :ok = GrpcProtoSets.delete(a.id)
      assert GrpcProtoSets.list() == []
      assert GrpcProtoSets.get(a.id) == nil
    end
  end

  describe "resolve_paths/2" do
    test "devuelve {proto_paths, import_paths} con / y bajo el dir del set" do
      {protos, imports} = GrpcProtoSets.resolve_paths("abc123", "donavida/auth/v1/auth.proto")
      assert [proto] = protos
      assert [root] = imports
      assert String.ends_with?(proto, "abc123/donavida/auth/v1/auth.proto")
      assert String.ends_with?(root, "abc123")
      refute String.contains?(proto, "\\")
    end
  end
end
