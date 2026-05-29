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
end
