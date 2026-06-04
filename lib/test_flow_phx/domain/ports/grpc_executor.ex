defmodule TestFlowPhx.Domain.Ports.GrpcExecutor do
  @moduledoc """
  Puerto (behaviour) para ejecutar un `Grpc.Request` contra un servidor gRPC.

  Paralelo a `TestFlowPhx.Domain.Ports.HttpExecutor`. El dominio depende solo de
  este contrato; el adapter concreto (`TestFlowPhx.Infrastructure.Grpc.GrpcExecutor`)
  se cablea vía `Application.get_env/2` en el límite del use case, y es quien
  carga el `.proto`, convierte el body JSON y habla HTTP/2 — el dominio no conoce
  protobuf ni Mint.

  ## Opciones reconocidas en `opts`

    * `:on_message` — fun aridad 1 invocada por cada mensaje en server streaming,
      a medida que llega (para empuje en vivo a la UI). El executor igual los
      acumula en `Response.messages`.
    * `:timeout` — ms.
  """

  alias TestFlowPhx.Domain.Grpc.{Request, Response}

  @callback send(Request.t(), keyword()) :: Response.t()
end
