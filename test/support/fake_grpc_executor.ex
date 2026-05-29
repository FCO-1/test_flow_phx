defmodule TestFlowPhx.Support.FakeGrpcExecutor do
  @moduledoc """
  Test adapter de `TestFlowPhx.Domain.Ports.GrpcExecutor`.

  Permite stagear un `%Grpc.Response{}` y luego inspeccionar el request
  capturado, sin I/O de red ni `protoc`. Si la respuesta stageada es streaming
  (`streaming?: true`) y `opts` trae `:on_message`, reproduce cada mensaje de
  `messages` por el callback — así los tests de empuje en vivo no necesitan red.

  Backend: `Application.put_env` (no el process dictionary) para que sea visible
  aunque el executor corra en otro proceso (Task de LiveView). Requiere
  `async: false` en tests que stagean.
  """

  @behaviour TestFlowPhx.Domain.Ports.GrpcExecutor

  alias TestFlowPhx.Domain.Grpc.Response

  @stage_key :fake_grpc_stage
  @last_request_key :fake_grpc_last_request
  @gate_key :fake_grpc_gate

  @doc "Stagea la respuesta que devolverá el próximo `send/2`."
  @spec stage(Response.t()) :: :ok
  def stage(%Response{} = response) do
    Application.put_env(:test_flow_phx, @stage_key, response)
    :ok
  end

  @doc "Devuelve el request capturado por el último `send/2` (o nil)."
  def last_request, do: Application.get_env(:test_flow_phx, @last_request_key)

  @doc "Limpia la respuesta stageada, el último request y el gate."
  def reset do
    Application.delete_env(:test_flow_phx, @stage_key)
    Application.delete_env(:test_flow_phx, @last_request_key)
    Application.delete_env(:test_flow_phx, @gate_key)
    :ok
  end

  @doc """
  Activa el "gate": tras replicar los mensajes, `send/2` avisa a `pid` con
  `{:fake_grpc_blocking, self()}` y se **bloquea** hasta recibir
  `:fake_grpc_release` (o 2s de timeout). Permite a los tests observar el estado
  in-flight (streaming en vivo) y ejercitar el cancel.
  """
  def gate(pid \\ self()), do: Application.put_env(:test_flow_phx, @gate_key, pid)

  @impl true
  def send(request, opts \\ []) do
    Application.put_env(:test_flow_phx, @last_request_key, request)

    response =
      case Application.get_env(:test_flow_phx, @stage_key) do
        %Response{} = r -> r
        nil -> %Response{status: 0}
      end

    replay_messages(response, Keyword.get(opts, :on_message))
    maybe_block()
    response
  end

  defp replay_messages(%Response{streaming?: true, messages: msgs}, cb) when is_function(cb, 1),
    do: Enum.each(msgs, cb)

  defp replay_messages(_response, _cb), do: :ok

  defp maybe_block do
    case Application.get_env(:test_flow_phx, @gate_key) do
      pid when is_pid(pid) ->
        Kernel.send(pid, {:fake_grpc_blocking, self()})

        receive do
          :fake_grpc_release -> :ok
        after
          2_000 -> :ok
        end

      _ ->
        :ok
    end
  end
end
