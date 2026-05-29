defmodule TestFlowPhxWeb.GrpcLive.Format do
  @moduledoc """
  Helpers de presentación para el template gRPC (formateo de valores y errores).
  Análogo a `RestLive.Styles`/`Parsers`: lógica chica de view fuera del `index.ex`.
  """

  @doc "JSON pretty para mostrar un valor decodificado; tolera no-serializable."
  def pretty(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(value, pretty: true)
    end
  end

  @doc "Traduce un átomo de error de upload a texto legible."
  def upload_error(:too_large), do: "demasiado grande"
  def upload_error(:too_many_files), do: "demasiados archivos"
  def upload_error(:not_accepted), do: "tipo no permitido"
  def upload_error(other), do: to_string(other)
end
