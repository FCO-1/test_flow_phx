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
end
