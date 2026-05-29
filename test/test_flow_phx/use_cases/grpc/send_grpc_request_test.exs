defmodule TestFlowPhx.UseCases.Grpc.SendGrpcRequestTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.Grpc.{Request, Response}
  alias TestFlowPhx.Support.FakeGrpcExecutor
  alias TestFlowPhx.UseCases.Grpc.SendGrpcRequest

  setup do
    FakeGrpcExecutor.reset()
    on_exit(&FakeGrpcExecutor.reset/0)
    :ok
  end

  defp req(attrs \\ %{}) do
    Request.new(
      Map.merge(
        %{target: "localhost:50051", proto_paths: ["x.proto"], service: "g.Greeter", method: "Hello", body_text: ~s({"msg":"hi"})},
        attrs
      )
    )
  end

  test "unary: devuelve la respuesta stageada y captura el request" do
    FakeGrpcExecutor.stage(%Response{status: 0, body_decoded: %{"reply" => "hola"}})

    resp = SendGrpcRequest.execute(req())

    assert resp.status == 0
    assert resp.body_decoded == %{"reply" => "hola"}
    assert FakeGrpcExecutor.last_request().service == "g.Greeter"
  end

  test "vars: resuelve {{var}} en target, body_text y valores de metadata antes de enviar" do
    FakeGrpcExecutor.stage(%Response{status: 0})

    request =
      req(%{
        target: "{{host}}",
        body_text: ~s({"name":"{{user}}"}),
        metadata: [%{key: "x-token", value: "{{token}}", enabled: true}]
      })

    SendGrpcRequest.execute(request, vars: %{"host" => "1.2.3.4:9000", "user" => "ada", "token" => "secret"})

    captured = FakeGrpcExecutor.last_request()
    assert captured.target == "1.2.3.4:9000"
    assert captured.body_text == ~s({"name":"ada"})
    assert [%{key: "x-token", value: "secret"}] = captured.metadata
  end

  test "server streaming: reproduce messages por :on_message y los devuelve en la respuesta" do
    FakeGrpcExecutor.stage(%Response{status: 0, streaming?: true, messages: [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]})

    parent = self()
    resp = SendGrpcRequest.execute(req(), on_message: fn m -> send(parent, {:msg, m}) end)

    assert resp.streaming?
    assert resp.messages == [%{"n" => 1}, %{"n" => 2}, %{"n" => 3}]
    assert_received {:msg, %{"n" => 1}}
    assert_received {:msg, %{"n" => 2}}
    assert_received {:msg, %{"n" => 3}}
  end

  test "error gRPC se propaga en el Response" do
    FakeGrpcExecutor.stage(%Response{status: 5, message: "not found", error: %{type: :grpc, code: 5, message: "not found"}})

    resp = SendGrpcRequest.execute(req())

    assert resp.status == 5
    assert resp.error.type == :grpc
  end
end
