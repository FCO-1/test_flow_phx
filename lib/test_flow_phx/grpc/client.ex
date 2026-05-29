defmodule TestFlowPhx.Grpc.Client do
  @moduledoc """
  Cliente gRPC de alto nivel: teje `Http2Client` + `Frame` + `WireCodec`.

  Expone llamadas unary (Fase N.5) y server streaming (Fase N.6). Client/bidi
  streaming quedan fuera de scope en Fase N.

  Skeleton de Fase N.1 — implementación en N.5/N.6.

  ## Regla de acoplamiento

  Parte del cliente gRPC propio. Sus entradas son tipos genéricos (canal,
  nombres de service/method, descriptores protobuf, mapas) y sus salidas son
  tipos genéricos. La integración con TestFlow vive en
  `TestFlowPhx.UseCases.SendGrpcRequest` y en `Infrastructure.Grpc.*`.
  """

  @doc """
  Ejecuta una RPC unary y devuelve la respuesta decodificada.

  TODO(N.5): implementar.
  """
  @spec unary(
          channel :: term(),
          service :: String.t(),
          method :: String.t(),
          request_descriptor :: term(),
          response_descriptor :: term(),
          input_value :: map(),
          opts :: keyword()
        ) :: {:ok, map()} | {:error, %{code: integer(), message: String.t()}}
  def unary(_channel, _service, _method, _request_descriptor, _response_descriptor, _input_value, _opts \\ []),
    do: raise("TestFlowPhx.Grpc.Client.unary/7 no implementado (Fase N.5)")

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
      do: raise("TestFlowPhx.Grpc.Client.server_stream/8 no implementado (Fase N.6)")
end
