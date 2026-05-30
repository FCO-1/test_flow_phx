defmodule TestFlowPhx.UseCases.Grpc.GrpcHistory do
  @moduledoc """
  Historial del tester **gRPC**. Espejo de `UseCases.History` (REST) pero propio
  del protocolo: registra cada Send (cuerpo/mensajes a archivo + entry resumido),
  lista y limpia.

  El registro se hace acá (no dentro de `SendGrpcRequest.execute/2`, que mantiene
  su firma `Request -> Response` para no romper smoke/tests): la LiveView llama
  `record/2` al completarse el send. El cuerpo decodificado (unary) o la lista de
  mensajes (streaming) se persiste como JSON en `data/grpc/<fecha>/<epoch>.json`;
  el entry solo guarda el puntero + resumen (status, message, counts, error).

  El repo se resuelve en runtime vía `:grpc_collection_repo`; si no está corriendo
  (p. ej. test env sin storage) las operaciones degradan a no-op / lista vacía.
  """

  alias TestFlowPhx.Domain.Grpc.{HistoryEntry, Request, Response}
  alias TestFlowPhx.Infrastructure.Storage.Paths

  @spec list(pos_integer()) :: [HistoryEntry.t()]
  def list(limit \\ 50) when is_integer(limit) and limit > 0,
    do: call_repo(fn repo -> repo.list_history(limit) end, [])

  @spec clear() :: :ok
  def clear, do: call_repo(fn repo -> repo.clear_history() end, :ok)

  @doc """
  Registra un Send gRPC: persiste el cuerpo (o los mensajes) y appendea un
  `HistoryEntry` resumido. Devuelve el entry creado (o `nil` si no se pudo).
  """
  @spec record(Request.t(), Response.t()) :: HistoryEntry.t() | nil
  def record(%Request{} = request, %Response{} = response) do
    entry = build_entry(request, response, persist_body(response))
    call_repo(fn repo -> repo.append_history(entry) end, :ok)
    entry
  end

  # ----- internos -----

  defp build_entry(%Request{} = request, %Response{} = r, result_file) do
    %HistoryEntry{
      id: Request.new_id(),
      ran_at: DateTime.utc_now(),
      request: request,
      response_status: r.status,
      response_message: r.message,
      streaming?: r.streaming?,
      message_count: length(r.messages || []),
      response_duration_ms: r.duration_ms,
      response_error: r.error,
      result_file: result_file
    }
  end

  # Persiste el cuerpo como JSON. En error no hay cuerpo; en streaming guarda la
  # lista de mensajes; en unary el body decodificado.
  defp persist_body(%Response{error: err}) when not is_nil(err), do: nil

  defp persist_body(%Response{streaming?: true, messages: msgs}) when msgs not in [nil, []],
    do: write_json(msgs)

  defp persist_body(%Response{streaming?: false, body_decoded: body}) when not is_nil(body),
    do: write_json(body)

  defp persist_body(_), do: nil

  defp write_json(term) do
    path = Paths.result_file_now(:grpc, "application/json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(term, pretty: true))
    path
  rescue
    _ -> nil
  end

  defp call_repo(fun, default) when is_function(fun, 1) do
    case Application.get_env(:test_flow_phx, :grpc_collection_repo) do
      nil ->
        default

      repo ->
        try do
          fun.(repo)
        catch
          :exit, _ -> default
        end
    end
  end
end
