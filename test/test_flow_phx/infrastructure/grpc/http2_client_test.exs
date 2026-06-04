defmodule TestFlowPhx.Infrastructure.Grpc.Http2ClientTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Infrastructure.Grpc.Http2Client

  

  describe "colector (puro)" do
    test "acumula status, headers iniciales, data y done" do
      acc =
        Http2Client.init_collector()
        |> Http2Client.collect({:status, :ref, 200})
        |> Http2Client.collect({:headers, :ref, [{"content-type", "application/grpc"}]})
        |> Http2Client.collect({:data, :ref, "ab"})
        |> Http2Client.collect({:data, :ref, "cd"})
        |> Http2Client.collect({:done, :ref})

      assert acc.done?
      assert {:ok, resp} = Http2Client.finalize(acc)
      assert resp.status == 200
      assert resp.headers == [{"content-type", "application/grpc"}]
      assert resp.body == "abcd"
      assert resp.trailers == []
    end

    test "el segundo bloque de headers son trailers" do
      acc =
        Http2Client.init_collector()
        |> Http2Client.collect({:status, :ref, 200})
        |> Http2Client.collect({:headers, :ref, [{"content-type", "application/grpc"}]})
        |> Http2Client.collect({:data, :ref, "x"})
        |> Http2Client.collect({:headers, :ref, [{"grpc-status", "0"}, {"grpc-message", ""}]})
        |> Http2Client.collect({:done, :ref})

      {:ok, resp} = Http2Client.finalize(acc)
      assert resp.headers == [{"content-type", "application/grpc"}]
      assert resp.trailers == [{"grpc-status", "0"}, {"grpc-message", ""}]
    end

    test "trailers-only (sin data): headers iniciales y trailers separados" do
      acc =
        Http2Client.init_collector()
        |> Http2Client.collect({:status, :ref, 200})
        |> Http2Client.collect({:headers, :ref, [{"content-type", "application/grpc"}]})
        |> Http2Client.collect({:headers, :ref, [{"grpc-status", "5"}]})
        |> Http2Client.collect({:done, :ref})

      {:ok, resp} = Http2Client.finalize(acc)
      assert resp.trailers == [{"grpc-status", "5"}]
      assert resp.body == ""
    end

    test "error se propaga" do
      acc =
        Http2Client.init_collector()
        |> Http2Client.collect({:error, :ref, :closed})

      assert acc.done?
      assert Http2Client.finalize(acc) == {:error, :closed}
    end
  end

  describe "transporte real (Bandit h2c)" do
    defmodule EchoPlug do
      import Plug.Conn

      def init(o), do: o

      def call(conn, _) do
        {:ok, body, conn} = read_body(conn)

        conn
        |> put_resp_header("content-type", "application/grpc+proto")
        |> put_resp_header("x-http-protocol", Atom.to_string(get_http_protocol(conn)))
        |> send_resp(200, "echo:" <> body)
      end
    end

    setup do
      port = 50_000 + rem(:erlang.unique_integer([:positive]), 5000)
      start_supervised!({Bandit, plug: EchoPlug, scheme: :http, port: port, ip: {127, 0, 0, 1}})
      {:ok, port: port}
    end

    test "connect + request unary devuelve status/headers/body sobre HTTP/2", %{port: port} do
      {:ok, chan} = Http2Client.connect("127.0.0.1", port)

      assert {:ok, resp} =
               Http2Client.request(chan, "/svc.Greeter/Unary", [{"content-type", "application/grpc+proto"}], "ping")

      assert resp.status == 200
      assert resp.body == "echo:ping"
      assert {"x-http-protocol", "HTTP/2"} in resp.headers
      assert {"content-type", "application/grpc+proto"} in resp.headers

      Http2Client.close(chan)
    end

    test "dos requests sobre el mismo canal", %{port: port} do
      {:ok, chan} = Http2Client.connect("127.0.0.1", port)
      assert {:ok, %{body: "echo:a"}} = Http2Client.request(chan, "/s/M", [], "a")
      assert {:ok, %{body: "echo:bb"}} = Http2Client.request(chan, "/s/M", [], "bb")
      Http2Client.close(chan)
    end

    test "connect a puerto cerrado falla" do
      assert {:error, _} = Http2Client.connect("127.0.0.1", 1)
    end
  end

  describe "streaming (Bandit h2c)" do
    defmodule ChunkPlug do
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

        Enum.reduce(Keyword.fetch!(opts, :chunks), conn, fn c, conn ->
          {:ok, conn} = chunk(conn, c)
          conn
        end)
      end
    end

    defp start_chunk_server(opts) do
      port = 50_000 + rem(:erlang.unique_integer([:positive]), 5000)
      start_supervised!({Bandit, plug: {ChunkPlug, opts}, scheme: :http, port: port, ip: {127, 0, 0, 1}})
      {:ok, chan} = Http2Client.connect("127.0.0.1", port)
      on_exit(fn -> if Process.alive?(chan), do: Http2Client.close(chan) end)
      chan
    end

    # Junta los {:data, _} hasta :done; devuelve {data_concatenada, status, headers}.
    defp drain(ref, acc) do
      receive do
        {:grpc_stream, ^ref, {:status, s}} -> drain(ref, %{acc | status: s})
        {:grpc_stream, ^ref, {:headers, hs}} -> drain(ref, %{acc | headers: hs})
        {:grpc_stream, ^ref, {:data, d}} -> drain(ref, %{acc | data: acc.data <> d})
        {:grpc_stream, ^ref, :done} -> acc
      after
        2_000 -> flunk("no llegó :done")
      end
    end

    test "reenvía status, headers iniciales, data (posiblemente fragmentada) y done" do
      chan = start_chunk_server(chunks: ["aa", "bb", "cc"], grpc_status: "0")
      {:ok, ref} = Http2Client.stream_request(chan, "/svc.S/Stream", [], "go")

      assert_receive {:grpc_stream, ^ref, {:status, 200}}, 2_000
      acc = drain(ref, %{data: "", status: 200, headers: nil})

      assert {"content-type", "application/grpc+proto"} in acc.headers
      assert {"grpc-status", "0"} in acc.headers
      assert acc.data == "aabbcc"
    end

    test "cancel/2 aborta el stream y devuelve :ok" do
      chan = start_chunk_server(chunks: ["xx", "yy", "zz"], grpc_status: "0")
      {:ok, ref} = Http2Client.stream_request(chan, "/svc.S/Stream", [], "go")

      # esperar al menos el primer evento, luego cancelar
      assert_receive {:grpc_stream, ^ref, _}, 2_000
      assert Http2Client.cancel(chan, ref) == :ok

      # tras cancelar el ref ya no está registrado; el canal sigue vivo y usable
      assert Process.alive?(chan)
    end
  end
end
