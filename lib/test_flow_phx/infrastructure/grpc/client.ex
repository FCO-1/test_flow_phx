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
  Ejecuta una RPC server-streaming, invocando `callback` por cada mensaje.

  TODO(N.6): implementar.
  """
  @spec server_stream(
          channel :: term(),
          service :: String.t(),
          method :: String.t(),
          request_descriptor :: term(),
          response_descriptor :: term(),
          input_value :: map(),
          callback :: (map() -> any()),
          opts :: keyword()
        ) :: {:ok, :done} | {:error, %{code: integer(), message: String.t()}}
  def server_stream(
        _channel,
        _service,
        _method,
        _request_descriptor,
        _response_descriptor,
        _input_value,
        _callback,
        _opts \\ []
      ),
      do: raise("TestFlowPhx.Infrastructure.Grpc.Client.server_stream/8 no implementado (Fase N.6)")
end
