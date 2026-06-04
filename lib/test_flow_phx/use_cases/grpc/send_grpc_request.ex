defmodule TestFlowPhx.UseCases.Grpc.SendGrpcRequest do
  @moduledoc """
  Use case de aplicación: envía un `Grpc.Request` vía el puerto `GrpcExecutor`
  configurado. Paralelo a `UseCases.Rest.SendRequest`, pero más fino: la carga
  del `.proto`, la conversión JSON y el HTTP/2 viven en el adapter; aquí solo
  resolvemos variables y delegamos.

  ## Opciones

    * `:vars` — `%{name => value}` para resolver `{{var}}` en `target`, los
      valores de `metadata` y `body_text` **antes** de enviar (el `body_text`
      se resuelve como string crudo, antes del `Jason.decode` del adapter — los
      placeholders pueden vivir dentro de strings JSON).
    * `:on_message`, `:timeout` — se pasan tal cual al executor.

  History de gRPC queda fuera de scope por ahora (el `HistoryEntry` actual
  embebe un `Rest.Request`; unificar es trabajo de una fase posterior).
  """

  alias TestFlowPhx.Domain.Grpc.{Request, Response}
  alias TestFlowPhx.UseCases.Grpc.GrpcProtoSets
  alias TestFlowPhx.UseCases.Variables

  @spec execute(Request.t(), keyword()) :: Response.t()
  def execute(%Request{} = req, opts \\ []) do
    vars = Keyword.get(opts, :vars, %{})

    req
    |> resolve_proto_set()
    |> then(&if(map_size(vars) == 0, do: &1, else: resolve_vars(&1, vars)))
    |> grpc_executor().send(opts)
  end

  # Si el request apunta a un proto-set (forma portable), resolvemos sus rutas
  # concretas (`proto_paths`/`import_paths`) para que el executor las use. Si ya
  # trae rutas directas (legacy) o no hay set, se deja tal cual.
  defp resolve_proto_set(%Request{proto_set_id: id, entry_file: entry} = req)
       when is_binary(id) and is_binary(entry) and entry != "" do
    {proto_paths, import_paths} = GrpcProtoSets.resolve_paths(id, entry)
    %{req | proto_paths: proto_paths, import_paths: import_paths}
  end

  defp resolve_proto_set(%Request{} = req), do: req

  defp resolve_vars(%Request{} = req, vars) do
    %{
      req
      | target: Variables.resolve(req.target, vars),
        body_text: Variables.resolve(req.body_text, vars),
        metadata: Enum.map(req.metadata, &%{&1 | value: Variables.resolve(&1.value, vars)})
    }
  end

  defp grpc_executor, do: Application.fetch_env!(:test_flow_phx, :grpc_executor)
end
