defmodule TestFlowPhx.Infrastructure.Grpc.GrpcExecutor do
  @moduledoc """
  Adapter de infrastructure que implementa `TestFlowPhx.Domain.Ports.GrpcExecutor`.

  Es el único punto donde TestFlow y el motor gRPC se tocan: carga el `.proto`
  (`ProtoLoader`), resuelve el método, convierte el body JSON al mapa de
  WireCodec (`JsonCodec`), abre la conexión HTTP/2 y ejecuta vía `Client`
  (`unary/7` o `server_stream/8` según el descriptor del método). Nunca lanza:
  todo fallo se captura en `Response.error`.

  Server streaming: acumula los mensajes en `Response.messages` y, si `opts`
  trae `:on_message`, invoca el callback por cada uno (empuje en vivo).
  """

  @behaviour TestFlowPhx.Domain.Ports.GrpcExecutor

  alias TestFlowPhx.Domain.Grpc.Response
  alias TestFlowPhx.Infrastructure.Grpc.{Client, Http2Client, JsonCodec}
  alias TestFlowPhx.UseCases.Grpc.ProtoLoader

  @default_timeout 30_000

  @impl true
  @spec send(TestFlowPhx.Domain.Grpc.Request.t(), keyword()) :: Response.t()
  def send(req, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    result =
      with {:ok, desc} <- load_proto(req),
           {:ok, method} <- find_method(desc, req.service, req.method),
           {:ok, in_desc} <- fetch_message(desc, method.input_type),
           {:ok, out_desc} <- fetch_message(desc, method.output_type),
           {:ok, json} <- decode_json(req.body_text),
           {:ok, input} <- to_input(in_desc, json, desc),
           {:ok, host, port} <- parse_target(req.target) do
        run(req, method, in_desc, out_desc, desc, input, host, port, opts)
      end

    finalize(result, System.monotonic_time(:millisecond) - started)
  end

  # ── pipeline de preparación ─────────────────────────────────────────────────

  defp load_proto(req) do
    case ProtoLoader.load(req.proto_paths, import_paths: req.import_paths) do
      {:ok, desc} -> {:ok, desc}
      {:error, msg} -> {:error, %{type: :proto_load, message: msg, code: nil}}
    end
  end

  defp find_method(desc, service_name, method_name) do
    with %{methods: methods} <- Enum.find(desc.services, &(&1.name == service_name)),
         %{} = method <- Enum.find(methods, &(&1.name == method_name)) do
      {:ok, method}
    else
      _ ->
        {:error,
         %{type: :invalid_request, message: "método #{service_name}/#{method_name} no existe en el .proto", code: nil}}
    end
  end

  defp fetch_message(desc, type_name) do
    case Map.get(desc.messages_by_name, type_name) do
      nil -> {:error, %{type: :invalid_request, message: "mensaje #{type_name} no está en el .proto", code: nil}}
      msg -> {:ok, msg}
    end
  end

  defp decode_json(""), do: {:ok, %{}}

  defp decode_json(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, %{type: :invalid_json, message: "el body debe ser un objeto JSON", code: nil}}
      {:error, e} -> {:error, %{type: :invalid_json, message: Exception.message(e), code: nil}}
    end
  end

  defp to_input(in_desc, json, desc) do
    case JsonCodec.to_message(in_desc, json, desc.messages_by_name, desc.enums_by_name) do
      {:ok, input} -> {:ok, input}
      {:error, msg} -> {:error, %{type: :invalid_request, message: msg, code: nil}}
    end
  end

  defp parse_target(target) do
    case String.split(target, ":", parts: 2) do
      [host, port] when host != "" ->
        case Integer.parse(port) do
          {p, ""} -> {:ok, host, p}
          _ -> {:error, %{type: :invalid_request, message: "puerto inválido en target: #{inspect(target)}", code: nil}}
        end

      _ ->
        {:error, %{type: :invalid_request, message: "target debe ser host:port, recibí #{inspect(target)}", code: nil}}
    end
  end

  # ── ejecución ─────────────────────────────────────────────────────────────────

  defp run(req, method, in_desc, out_desc, desc, input, host, port, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case Http2Client.connect(host, port) do
      {:ok, chan} ->
        try do
          call_opts = [registry: desc.messages_by_name, metadata: metadata(req), timeout: timeout]
          dispatch(method, chan, req.service, in_desc, out_desc, desc, input, call_opts, opts)
        after
          Http2Client.close(chan)
        end

      {:error, reason} ->
        {:error, %{type: :transport, message: inspect(reason), code: :transport}}
    end
  end

  # unary
  defp dispatch(%{server_streaming?: false} = method, chan, service, in_desc, out_desc, desc, input, call_opts, _opts) do
    case Client.unary(chan, service, method.name, in_desc, out_desc, input, call_opts) do
      {:ok, map} ->
        {:ok, %{status: 0, body_decoded: JsonCodec.from_message(out_desc, map, desc.messages_by_name, desc.enums_by_name)}}

      {:error, err} ->
        {:error, grpc_error(err)}
    end
  end

  # server streaming: recolecta mensajes (en orden) sin proceso extra — el
  # callback los envía a self() y los drenamos al terminar; on_message empuja.
  defp dispatch(%{server_streaming?: true} = method, chan, service, in_desc, out_desc, desc, input, call_opts, opts) do
    me = self()
    tag = make_ref()
    on_message = Keyword.get(opts, :on_message)

    cb = fn map ->
      decoded = JsonCodec.from_message(out_desc, map, desc.messages_by_name, desc.enums_by_name)
      Kernel.send(me, {tag, decoded})
      # Propagar el retorno del callback del caller: si devuelve :halt, Client
      # cancela el stream (RST). Cualquier otra cosa continúa.
      if on_message, do: on_message.(decoded), else: :cont
    end

    case Client.server_stream(chan, service, method.name, in_desc, out_desc, input, cb, call_opts) do
      {:ok, _done_or_cancelled} -> {:ok, %{status: 0, streaming?: true, messages: drain(tag, [])}}
      {:error, err} -> {:error, Map.put(grpc_error(err), :messages, drain(tag, []))}
    end
  end

  defp drain(tag, acc) do
    receive do
      {^tag, msg} -> drain(tag, [msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp metadata(req) do
    for %{key: k, value: v, enabled: true} <- req.metadata, k != "" do
      {String.downcase(k), v}
    end
  end

  defp grpc_error(%{code: :transport, message: msg}), do: %{type: :transport, message: msg, code: :transport}
  defp grpc_error(%{code: code, message: msg}), do: %{type: :grpc, message: msg, code: code}

  # ── construcción del Response ─────────────────────────────────────────────────

  defp finalize({:ok, fields}, duration), do: struct(%Response{duration_ms: duration}, fields)

  defp finalize({:error, %{messages: messages} = err}, duration) do
    %Response{duration_ms: duration, streaming?: true, messages: messages, error: Map.delete(err, :messages)}
    |> put_status_from_error()
  end

  defp finalize({:error, err}, duration) do
    %Response{duration_ms: duration, error: err} |> put_status_from_error()
  end

  defp put_status_from_error(%Response{error: %{type: :grpc, code: code, message: msg}} = r),
    do: %{r | status: code, message: msg}

  defp put_status_from_error(r), do: r
end
