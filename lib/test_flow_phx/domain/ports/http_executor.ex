defmodule TestFlowPhx.Domain.Ports.HttpExecutor do
  @moduledoc """
  Port (behaviour) for executing a Request against a remote system.

  The domain depends only on this contract; the concrete adapter (currently
  `TestFlowPhx.Infrastructure.Http.ReqExecutor`) is wired in via
  `Application.get_env/2` at the use-case boundary, keeping the domain
  independent of any HTTP library.
  """

  alias TestFlowPhx.Domain.{Request, Response}

  @callback send(Request.t(), keyword()) :: Response.t()
end
