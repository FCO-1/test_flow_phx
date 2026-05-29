defmodule TestFlowPhx.Infrastructure.Grpc.GrpcExecutorTest do
  # async: false — ProtoLoader cachea en :persistent_term (global) + arranca servidores.
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.Grpc.Request
  alias TestFlowPhx.Infrastructure.Grpc.{Frame, GrpcExecutor, WireCodec}
  alias TestFlowPhx.UseCases.Grpc.ProtoLoader

  @proto """
  syntax = "proto3";
  package echo;
  message Req { string msg = 1; }
  message Resp { string reply = 1; }
  service Echoer {
    rpc Echo(Req) returns (Resp);
    rpc Down(Req) returns (stream Resp);
  }
  """

  # Plug tonto: envía `frames` crudos como chunks + grpc-status en headers
  # (Bandit no emite trailers vía Plug, igual que en los tests de Client).
  defmodule SendFramesPlug do
    @moduledoc false
    import Plug.Conn

    def init(o), do: o

    def call(conn, opts) do
      {:ok, _body, conn} = read_body(conn)

      conn =
        conn
        |> put_resp_header("content-type", "application/grpc+proto")
        |> put_resp_header("grpc-status", Keyword.get(opts, :grpc_status, "0"))
        |> send_chunked(200)

      Enum.reduce(Keyword.fetch!(opts, :frames), conn, fn f, conn ->
        {:ok, conn} = chunk(conn, f)
        conn
      end)
    end
  end

  setup do
    ProtoLoader.clear_cache()
    dir = Path.join(System.tmp_dir!(), "tf_grpcexec_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    proto = Path.join(dir, "echo.proto")
    File.write!(proto, @proto)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, d} = ProtoLoader.load([proto])
    resp_desc = d.messages_by_name[".echo.Resp"]
    frame = fn reply -> WireCodec.encode(resp_desc, %{"reply" => reply}, d.messages_by_name) |> Frame.encode() end

    %{proto: proto, frame: frame}
  end

  defp serve(frames) do
    port = 50_000 + rem(:erlang.unique_integer([:positive]), 5000)
    start_supervised!({Bandit, plug: {SendFramesPlug, frames: frames, grpc_status: "0"}, scheme: :http, port: port, ip: {127, 0, 0, 1}})
    port
  end

  defp req(proto, method, attrs) do
    Request.new(
      Map.merge(%{proto_paths: [proto], service: "echo.Echoer", method: method, body_text: ~s({"msg":"hi"})}, attrs)
    )
  end

  test "unary end-to-end: carga proto + JSON→wire + HTTP/2 + decode", %{proto: proto, frame: frame} do
    port = serve([frame.("eco!")])

    resp = GrpcExecutor.send(req(proto, "Echo", %{target: "127.0.0.1:#{port}"}))

    assert resp.status == 0
    assert resp.body_decoded == %{"reply" => "eco!"}
    assert resp.error == nil
  end

  test "server streaming end-to-end: acumula messages e invoca on_message", %{proto: proto, frame: frame} do
    port = serve([frame.("a"), frame.("b"), frame.("c")])
    parent = self()

    resp = GrpcExecutor.send(req(proto, "Down", %{target: "127.0.0.1:#{port}"}), on_message: fn m -> send(parent, {:m, m}) end)

    assert resp.streaming?
    assert resp.messages == [%{"reply" => "a"}, %{"reply" => "b"}, %{"reply" => "c"}]
    assert_received {:m, %{"reply" => "a"}}
    assert_received {:m, %{"reply" => "c"}}
  end

  test "método inexistente → error :invalid_request (sin tocar la red)", %{proto: proto} do
    resp = GrpcExecutor.send(req(proto, "Nope", %{target: "127.0.0.1:1"}))
    assert resp.error.type == :invalid_request
    assert resp.error.message =~ "Nope"
  end

  test "target mal formado → error :invalid_request", %{proto: proto} do
    resp = GrpcExecutor.send(req(proto, "Echo", %{target: "sin-puerto"}))
    assert resp.error.type == :invalid_request
  end

  test "body JSON inválido → error :invalid_json", %{proto: proto} do
    resp = GrpcExecutor.send(req(proto, "Echo", %{target: "127.0.0.1:1", body_text: "{no-json"}))
    assert resp.error.type == :invalid_json
  end
end
