defmodule TestFlowPhxWeb.GrpcLive.Format do
  @moduledoc """
  Helpers de presentación para el template gRPC (formateo de valores y errores).
  Análogo a `RestLive.Styles`/`Parsers`: lógica chica de view fuera del `index.ex`.
  """

  alias TestFlowPhx.UseCases.Translations

  @doc "JSON pretty para mostrar un valor decodificado; tolera no-serializable."
  def pretty(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, pretty: true)
    end
  end

  @doc "Traduce un átomo de error de upload a texto legible (localizado)."
  def upload_error(locale, err) when err in [:too_large, :too_many_files, :not_accepted],
    do: Translations.t(locale, "grpc.upload_errors.#{err}")

  def upload_error(_locale, other), do: to_string(other)

  @doc """
  Adapta una entrada de historial gRPC (`Domain.Grpc.HistoryEntry`) al shape
  agnóstico que espera `TesterComponents.history_sidebar`: `id`, `method` (token
  mono coloreado — "OK"/código grpc/"ERR"), `label` (service/method), `status`
  (resumen textual) y `meta` (hora · duración).
  """
  def history_entry(e) do
    %{
      id: e.id,
      method: history_method(e),
      label: "#{e.request.service}/#{e.request.method}",
      status: history_status(e),
      meta: history_meta(e)
    }
  end

  # Token prominente: "OK" en grpc-status 0, el código numérico en errores grpc,
  # "ERR" en fallos de transporte (sin grpc-status pero con error).
  defp history_method(%{response_status: 0}), do: "OK"
  defp history_method(%{response_status: n}) when is_integer(n), do: Integer.to_string(n)
  defp history_method(_), do: "ERR"

  defp history_status(%{streaming?: true, message_count: n}) when n > 0, do: "#{n} msgs"

  defp history_status(%{response_message: msg}) when is_binary(msg) and msg != "", do: msg

  defp history_status(%{response_error: %{message: msg}}) when is_binary(msg) and msg != "",
    do: msg

  defp history_status(%{response_status: 0}), do: "OK"
  defp history_status(_), do: "error"

  defp history_meta(%{ran_at: %DateTime{} = at, response_duration_ms: ms})
       when is_integer(ms) and ms > 0,
       do: "#{Calendar.strftime(at, "%H:%M:%S")} · #{ms} ms"

  defp history_meta(%{ran_at: %DateTime{} = at}), do: Calendar.strftime(at, "%H:%M:%S")

  defp history_meta(_), do: nil
end
