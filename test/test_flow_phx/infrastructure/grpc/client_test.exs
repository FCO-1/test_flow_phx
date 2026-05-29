defmodule TestFlowPhx.Infrastructure.Grpc.ClientTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Infrastructure.Grpc.{Client, Frame, Http2Client, WireCodec}
  alias Google.Protobuf.{DescriptorProto, FieldDescriptorProto}

  # ── descriptores de prueba (Echo) ───────────────────────────────────────────

  @req %DescriptorProto{name: "EchoReq", field: [%FieldDescriptorProto{name: "msg", number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]}
  @resp %DescriptorProto{name: "EchoResp", field: [%FieldDescriptorProto{name: "reply", number: 1, type: :TYPE_STRING, label: :LABEL_OPTIONAL}]}

  # frame de un EchoResp, como lo mandaría un server
  defp resp_frame(reply), do: WireCodec.encode(@resp, %{"reply" => reply}) |> Frame.encode()

  # ── interpret_response (puro) ───────────────────────────────────────────────

  describe "interpret_response/3 (semántica gRPC)" do
    test "éxito: grpc-status 0 en trailers + body decodificado" do
      resp = %{
        status: 200,
        headers: [{"content-type", "application/grpc+proto"}],
        trailers: [{"grpc-status", "0"}],
        body: resp_frame("hola")
      }

      assert Client.interpret_response(resp, @resp, %{}) == {:ok, %{"reply" => "hola"}}
    end

    test "éxito Trailers-Only-fallback: grpc-status 0 en headers iniciales" do
      resp = %{status: 200, headers: [{"grpc-status", "0"}], trailers: [], body: resp_frame("hey")}
      assert Client.interpret_response(resp, @resp, %{}) == {:ok, %{"reply" => "hey"}}
    end

    test "error: grpc-status != 0 → {:error, %{code, message}}" do
      resp = %{
        status: 200,
        headers: [{"content-type", "application/grpc"}],
        trailers: [{"grpc-status", "5"}, {"grpc-message", "not found"}],
        body: ""
      }

      assert Client.interpret_response(resp, @resp, %{}) == {:error, %{code: 5, message: "not found"}}
    end

    test "trailers ganan sobre headers" do
      resp = %{
        status: 200,
        headers: [{"grpc-status", "0"}],
        trailers: [{"grpc-status", "13"}, {"grpc-message", "internal"}],
        body: ""
      }

      assert {:error, %{code: 13}} = Client.interpret_response(resp, @resp, %{})
    end

    test "sin grpc-status → error claro" do
      resp = %{status: 200, headers: [], trailers: [], body: ""}
      assert {:error, %{code: :unknown, message: msg}} = Client.interpret_response(resp, @resp, %{})
      assert msg =~ "sin grpc-status"
    end

    test "respuesta con body vacío (frame ausente) → mapa vacío" do
      resp = %{status: 200, headers: [], trailers: [{"grpc-status", "0"}], body: ""}
      assert Client.interpret_response(resp, @resp, %{}) == {:ok, %{}}
    end
  end

  # ── end-to-end real sobre HTTP/2 (Bandit) ───────────────────────────────────

  defmodule GrpcEchoPlug do
    @moduledoc false
    import Plug.Conn
    alias TestFlowPhx.Infrastructure.Grpc.{Frame, WireCodec}

    def init(opts), do: opts

    def call(conn, %{req: req, resp: resp}) do
      {:ok, body, conn} = read_body(conn)
      {[frame | _], _} = Frame.decode(body)
      %{"msg" => msg} = WireCodec.decode(req, frame, %{})

      # asserts del lado servidor: el request gRPC llegó bien formado
      assert_grpc!(conn)

      cond do
        msg == "boom" ->
          # error gRPC (Trailers-Only-style, ya que Bandit no emite trailers)
          conn
          |> put_resp_header("content-type", "application/grpc+proto")
          |> put_resp_header("grpc-status", "5")
          |> put_resp_header("grpc-message", "explotó")
          |> send_resp(200, "")

        true ->
          out = WireCodec.encode(resp, %{"reply" => "eco: " <> msg}, %{}) |> Frame.encode()

          conn
          |> put_resp_header("content-type", "application/grpc+proto")
          |> put_resp_header("grpc-status", "0")
          |> send_resp(200, out)
      end
    end

    defp assert_grpc!(conn) do
      "application/grpc+proto" = get_req_header(conn, "content-type") |> List.first()
      "trailers" = get_req_header(conn, "te") |> List.first()
      "POST" = conn.method
      "/echo.Echoer/Echo" = conn.request_path
    end
  end

  describe "unary/7 end-to-end (Bandit h2c)" do
    setup do
      port = 50_000 + rem(:erlang.unique_integer([:positive]), 5000)
      start_supervised!({Bandit, plug: {GrpcEchoPlug, %{req: @req, resp: @resp}}, scheme: :http, port: port, ip: {127, 0, 0, 1}})
      {:ok, chan} = Http2Client.connect("127.0.0.1", port)
      on_exit(fn -> if Process.alive?(chan), do: Http2Client.close(chan) end)
      {:ok, chan: chan}
    end

    test "request encode/frame/headers + response deframe/decode sobre la red", %{chan: chan} do
      assert {:ok, %{"reply" => "eco: mundo"}} =
               Client.unary(chan, "echo.Echoer", "Echo", @req, @resp, %{"msg" => "mundo"})
    end

    test "error gRPC del servidor se mapea a {:error, %{code, message}}", %{chan: chan} do
      assert {:error, %{code: 5, message: "explotó"}} =
               Client.unary(chan, "echo.Echoer", "Echo", @req, @resp, %{"msg" => "boom"})
    end

    test "metadata custom viaja como header", %{chan: chan} do
      # el server no la valida, pero confirmamos que no rompe el flujo
      assert {:ok, %{"reply" => "eco: x"}} =
               Client.unary(chan, "echo.Echoer", "Echo", @req, @resp, %{"msg" => "x"},
                 metadata: [{"x-api-key", "secret"}]
               )
    end
  end
end
