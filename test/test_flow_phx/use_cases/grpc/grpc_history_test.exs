defmodule TestFlowPhx.UseCases.Grpc.GrpcHistoryTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Domain.Grpc.{HistoryEntry, Request, Response}
  alias TestFlowPhx.Infrastructure.Storage.GrpcJsonFileRepo, as: Repo
  alias TestFlowPhx.UseCases.Grpc.GrpcHistory

  setup do
    tmp = Path.join(System.tmp_dir!(), "tf_grpc_hist_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    # Los result files se escriben en `data_dir/grpc/<fecha>/...`; apuntalo al tmp
    # para no contaminar ./data y poder releerlos.
    Application.put_env(:test_flow_phx, :data_dir_override, tmp)

    on_exit(fn ->
      Application.delete_env(:test_flow_phx, :data_dir_override)
      File.rm_rf!(tmp)
    end)

    start_supervised!({Repo, name: Repo, path: Path.join(tmp, "state.json"), flush_after_ms: 10})
    :ok
  end

  defp req(method),
    do: %Request{name: "r", target: "h:1", service: "svc.S", method: method}

  test "record (unary OK) persiste el body como JSON y appendea un entry resumido" do
    resp = %Response{status: 0, body_decoded: %{"reply" => "hola"}, duration_ms: 12}

    entry = GrpcHistory.record(req("Echo"), resp)

    assert %HistoryEntry{response_status: 0, streaming?: false, message_count: 0} = entry
    assert entry.request.method == "Echo"
    assert is_binary(entry.result_file)
    assert File.exists?(entry.result_file)
    assert entry.result_file |> File.read!() |> Jason.decode!() == %{"reply" => "hola"}

    assert [listed] = GrpcHistory.list()
    assert listed.id == entry.id

    # to_response reconstruye el resultado visible (cuerpo releído del archivo).
    assert %Response{status: 0, streaming?: false, body_decoded: %{"reply" => "hola"}, messages: []} =
             GrpcHistory.to_response(entry)
  end

  test "record (error) no escribe body y guarda el error" do
    resp = %Response{status: 16, message: "X", error: %{type: :grpc, message: "bad", code: 16}}

    entry = GrpcHistory.record(req("IniciarSesion"), resp)

    assert entry.result_file == nil
    assert entry.response_status == 16
    assert entry.response_error == %{type: :grpc, message: "bad", code: 16}

    # to_response: sin cuerpo, pero conserva status y error para re-visualizar.
    resp_back = GrpcHistory.to_response(entry)
    assert resp_back.status == 16
    assert resp_back.body_decoded == nil
    assert resp_back.error == %{type: :grpc, message: "bad", code: 16}
  end

  test "record (streaming) guarda los mensajes y el conteo" do
    resp = %Response{status: 0, streaming?: true, messages: [%{"n" => 1}, %{"n" => 2}]}

    entry = GrpcHistory.record(req("Down"), resp)

    assert entry.streaming? and entry.message_count == 2
    assert entry.result_file |> File.read!() |> Jason.decode!() == [%{"n" => 1}, %{"n" => 2}]

    # to_response: streaming releído como lista de mensajes, body_decoded nil.
    resp_back = GrpcHistory.to_response(entry)
    assert resp_back.streaming? and resp_back.body_decoded == nil
    assert resp_back.messages == [%{"n" => 1}, %{"n" => 2}]
  end

  test "list (más reciente primero) y clear" do
    GrpcHistory.record(req("A"), %Response{status: 0, body_decoded: %{}})
    GrpcHistory.record(req("B"), %Response{status: 0, body_decoded: %{}})

    assert ["B", "A"] = GrpcHistory.list() |> Enum.map(& &1.request.method)

    assert :ok = GrpcHistory.clear()
    assert [] = GrpcHistory.list()
  end
end
