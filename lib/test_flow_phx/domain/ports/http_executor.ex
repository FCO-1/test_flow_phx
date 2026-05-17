defmodule TestFlowPhx.Domain.Ports.HttpExecutor do
  @moduledoc """
  Puerto (behaviour) para ejecutar un Request contra un sistema remoto.

  El dominio depende solo de este contrato; el adapter concreto
  (actualmente `TestFlowPhx.Infrastructure.Http.ReqExecutor`) se cablea
  vía `Application.get_env/2` en el límite del use case, manteniendo el
  dominio independiente de cualquier librería HTTP.
  """

  alias TestFlowPhx.Domain.{Request, Response}

  @callback send(Request.t(), keyword()) :: Response.t()
end
