defmodule TestFlowPhx.Infrastructure.Grpc.Client do
  @moduledoc """
  Cliente gRPC de alto nivel: teje `Http2Client` + `Frame` + `WireCodec`.

  Expone llamadas unary (Fase N.5) y server streaming (Fase N.6). Client/bidi
  streaming quedan fuera de scope en Fase N.

  ## Camino unary

  `unary/7` codifica `input_value` con `WireCodec` → lo enmarca con `Frame` →
  hace POST por `Http2Client` a `/<service>/<method>` con los headers gRPC
  (`content-type: application/grpc+proto`, `te: trailers`, + metadata) → lee la
  respuesta (1 frame de body + `grpc-status`/`grpc-message`) → decodifica.

  El `grpc-status` se busca primero en **trailers** y como fallback en los
  headers iniciales (responses *Trailers-Only*). status 0 → `{:ok, mapa}`;
  status != 0 → `{:error, %{code, message}}`.

  ## Regla de acoplamiento

  Parte del cliente gRPC propio. Sus entradas son tipos genéricos (canal,
  nombres de service/method, descriptores protobuf, mapas) y sus salidas son
  tipos genéricos. La integración con TestFlow vive en
  `TestFlowPhx.UseCases.Grpc.SendGrpcRequest` y en `Infrastructure.Grpc.*`.
  """

  alias TestFlowPhx.Infrastructure.Grpc.{Frame, Http2Client, WireCodec}

  @content_type "application/grpc+proto"

  @typedoc "Error gRPC: `code` numérico (0-16) o átomo de transporte; `message`."
  @type error :: %{code: non_neg_integer() | atom(), message: String.t()}

  @doc """
  Ejecuta una RPC unary y devuelve la respuesta decodificada.

  Opts: `registry` (`%{type_name => DescriptorProto}` para anidados),
  `metadata` (lista `[{header, value}]` custom), `timeout` (ms, default 30s).
  """
  @spec unary(
          pid(),
          String.t(),
          String.t(),
          Google.Protobuf.DescriptorProto.t(),
          Google.Protobuf.DescriptorProto.t(),
          map(),
          keyword()
        ) :: {:ok, map()} | {:error, error()}
  def unary(channel, service, method, request_descriptor, response_descriptor, input_value, opts \\ []) do
    registry = Keyword.get(opts, :registry, %{})
    metadata = Keyword.get(opts, :metadata, [])
    timeout = Keyword.get(opts, :timeout, 30_000)

    path = "/" <> service <> "/" <> method
    body = input_value |> then(&WireCodec.encode(request_descriptor, &1, registry)) |> Frame.encode()
    headers = grpc_headers() ++ metadata

    case Http2Client.request(channel, path, headers, body, timeout: timeout) do
      {:ok, http_response} -> interpret_response(http_response, response_descriptor, registry)
      {:error, reason} -> {:error, %{code: :transport, message: inspect(reason)}}
    end
  end

  defp grpc_headers,
    do: [{"content-type", @content_type}, {"te", "trailers"}, {"user-agent", "tf-grpc/0.1"}]

  @doc false
  # Interpreta el response HTTP/2 (status/headers/trailers/body) según la
  # semántica gRPC. Puro: testeable sin red.
  @spec interpret_response(map(), Google.Protobuf.DescriptorProto.t(), map()) ::
          {:ok, map()} | {:error, error()}
  def interpret_response(http_response, response_descriptor, registry) do
    case grpc_status(http_response) do
      {0, _msg} -> decode_body(http_response.body, response_descriptor, registry)
      {code, msg} -> {:error, %{code: code, message: msg}}
      :missing -> {:error, missing_status_error(http_response)}
    end
  end

  # trailers tienen precedencia sobre headers (Trailers-Only fallback).
  defp grpc_status(%{trailers: trailers, headers: headers}) do
    all = trailers ++ headers

    case List.keyfind(all, "grpc-status", 0) do
      {_, code} -> {String.to_integer(code), grpc_message(all)}
      nil -> :missing
    end
  end

  defp grpc_message(headers) do
    case List.keyfind(headers, "grpc-message", 0) do
      {_, msg} -> msg
      nil -> ""
    end
  end

  defp decode_body(body, response_descriptor, registry) do
    case Frame.decode(body) do
      {[frame | _], _rest} -> {:ok, WireCodec.decode(response_descriptor, frame, registry)}
      {[], _rest} -> {:ok, %{}}
    end
  end

  defp missing_status_error(%{status: 200}),
    do: %{code: :unknown, message: "respuesta gRPC sin grpc-status"}

  defp missing_status_error(%{status: status}),
    do: %{code: :unknown, message: "HTTP #{status} sin grpc-status"}

  @doc """
  Ejecuta una RPC server-streaming, invocando `callback` por cada mensaje
  decodificado a medida que llega.

  El request se codifica/enmarca igual que en `unary/7`. La respuesta llega como
  múltiples DATA frames de HTTP/2; un mensaje puede partirse entre frames, así
  que se mantiene un buffer y se desenmarca con `Frame.decode/1` (que devuelve el
  resto parcial). Cada payload completo se decodifica con `WireCodec` y se pasa a
  `callback`.

  `callback` puede devolver `:halt` para cancelar el stream (RST_STREAM); en ese
  caso devuelve `{:ok, :cancelled}`. Cualquier otro retorno continúa.

  Al cerrarse el stream se lee `grpc-status` (trailers, con fallback a headers):
  0 → `{:ok, :done}`; != 0 → `{:error, %{code, message}}`. Opts iguales a
  `unary/7` (`registry`, `metadata`, `timeout`).
  """
  @spec server_stream(
          pid(),
          String.t(),
          String.t(),
          Google.Protobuf.DescriptorProto.t(),
          Google.Protobuf.DescriptorProto.t(),
          map(),
          (map() -> any()),
          keyword()
        ) :: {:ok, :done | :cancelled} | {:error, error()}
  def server_stream(channel, service, method, request_descriptor, response_descriptor, input_value, callback, opts \\ []) do
    registry = Keyword.get(opts, :registry, %{})
    metadata = Keyword.get(opts, :metadata, [])
    timeout = Keyword.get(opts, :timeout, 30_000)

    path = "/" <> service <> "/" <> method
    body = input_value |> then(&WireCodec.encode(request_descriptor, &1, registry)) |> Frame.encode()
    headers = grpc_headers() ++ metadata

    case Http2Client.stream_request(channel, path, headers, body, timeout: timeout) do
      {:ok, ref} ->
        consume_stream(channel, ref, %{
          buffer: "",
          status: nil,
          headers: [],
          trailers: [],
          descriptor: response_descriptor,
          registry: registry,
          callback: callback,
          timeout: timeout
        })

      {:error, reason} ->
        {:error, %{code: :transport, message: inspect(reason)}}
    end
  end

  defp consume_stream(channel, ref, acc) do
    receive do
      {:grpc_stream, ^ref, event} -> handle_stream_event(event, channel, ref, acc)
    after
      acc.timeout -> {:error, %{code: :transport, message: "timeout"}}
    end
  end

  defp handle_stream_event({:status, status}, channel, ref, acc),
    do: consume_stream(channel, ref, %{acc | status: status})

  defp handle_stream_event({:headers, hs}, channel, ref, acc),
    do: consume_stream(channel, ref, %{acc | headers: hs})

  defp handle_stream_event({:trailers, hs}, channel, ref, acc),
    do: consume_stream(channel, ref, %{acc | trailers: hs})

  defp handle_stream_event({:data, data}, channel, ref, acc) do
    {payloads, rest} = Frame.decode(acc.buffer <> data)

    case deliver(payloads, acc) do
      :cont ->
        consume_stream(channel, ref, %{acc | buffer: rest})

      :halt ->
        Http2Client.cancel(channel, ref)
        {:ok, :cancelled}
    end
  end

  defp handle_stream_event(:done, _channel, _ref, acc), do: finalize_stream(acc)

  defp handle_stream_event({:error, reason}, _channel, _ref, _acc),
    do: {:error, %{code: :transport, message: inspect(reason)}}

  # Decodifica e invoca el callback por payload; corta en cuanto devuelve :halt.
  defp deliver([], _acc), do: :cont

  defp deliver([payload | rest], acc) do
    case acc.callback.(WireCodec.decode(acc.descriptor, payload, acc.registry)) do
      :halt -> :halt
      _ -> deliver(rest, acc)
    end
  end

  defp finalize_stream(acc) do
    case grpc_status(acc) do
      {0, _msg} -> {:ok, :done}
      {code, msg} -> {:error, %{code: code, message: msg}}
      :missing -> {:error, missing_status_error(acc)}
    end
  end
end
