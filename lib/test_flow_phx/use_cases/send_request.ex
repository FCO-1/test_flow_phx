defmodule TestFlowPhx.UseCases.SendRequest do
  @moduledoc """
  Use case de aplicación: envía un Request vía el puerto HttpExecutor
  configurado y (opcionalmente) appendea un HistoryEntry resumido vía el
  puerto RequestRepo.

  Es el único puente entre la capa web (LiveView) y el mundo exterior.
  Depende de entidades de dominio y puertos — nunca de una librería HTTP
  específica ni de un backend de storage concreto.
  """

  alias TestFlowPhx.Domain.{HistoryEntry, Request, Response}
  alias TestFlowPhx.Infrastructure.Storage.Paths

  @spec execute(Request.t(), keyword()) :: {Response.t(), HistoryEntry.t() | nil}
  def execute(%Request{} = request, opts \\ []) do
    response = http_executor().send(request, opts)

    history_entry =
      if Keyword.get(opts, :record_history?, true) do
        result_file =
          if Keyword.get(opts, :persist_body?, true),
            do: maybe_persist_body(response),
            else: nil

        entry = build_history_entry(request, response, result_file)
        maybe_append_history(entry)
        entry
      else
        nil
      end

    {response, history_entry}
  end

  defp build_history_entry(%Request{} = request, %Response{} = response, result_file) do
    %HistoryEntry{
      id: Request.new_id(),
      ran_at: DateTime.utc_now(),
      request: request,
      response_status: response.status,
      response_duration_ms: response.duration_ms,
      response_size_bytes: response.size_bytes,
      response_error: response.error,
      result_file: result_file
    }
  end

  defp maybe_persist_body(%Response{error: err}) when not is_nil(err), do: nil
  defp maybe_persist_body(%Response{body: nil}), do: nil
  defp maybe_persist_body(%Response{body: ""}), do: nil

  defp maybe_persist_body(%Response{body: body, headers: headers}) when is_binary(body) do
    content_type =
      Enum.find_value(headers || [], fn
        {"content-type", v} -> v
        _ -> nil
      end)

    path = Paths.result_file_now(:rest, content_type)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  rescue
    _ -> nil
  end

  defp maybe_persist_body(_), do: nil

  defp maybe_append_history(entry) do
    repo = request_repo()

    if repo do
      try do
        repo.append_history(entry)
      catch
        :exit, _ -> :ok
      end
    else
      :ok
    end
  end

  defp http_executor do
    Application.fetch_env!(:test_flow_phx, :http_executor)
  end

  defp request_repo do
    Application.get_env(:test_flow_phx, :request_repo)
  end
end
