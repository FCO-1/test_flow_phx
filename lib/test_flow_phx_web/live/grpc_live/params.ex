defmodule TestFlowPhxWeb.GrpcLive.Params do
  @moduledoc """
  Mapea los params del form gRPC (`request[...]`) a un `%Grpc.Request{}`.

  Espejo de `TestFlowPhxWeb.RequestParams` en el lado REST: mantiene el
  `index.ex` enfocado en rutear eventos y deja acá la traducción form → struct,
  incluida la regla de "resetear el method si el service cambió".
  """

  alias TestFlowPhx.Domain.Grpc.Request
  alias TestFlowPhxWeb.GrpcLive.Proto

  @doc """
  Aplica los campos presentes en `form` sobre `request`. `proto` se usa para
  validar el method contra el service elegido.
  """
  def apply(%Request{} = request, proto, form) do
    service = Map.get(form, "service", request.service)

    %{
      request
      | target: Map.get(form, "target", request.target),
        body_text: Map.get(form, "body_text", request.body_text),
        service: service,
        method: valid_method(proto, service, Map.get(form, "method", request.method)),
        metadata: kv_field(form, "metadata", request.metadata),
        extractions: kv_field(form, "extractions", request.extractions)
    }
  end

  defp kv_field(form, key, current) do
    case form[key] do
      nil -> current
      rows -> parse_kv_rows(rows)
    end
  end

  # Si el method no existe en el service seleccionado, cae al primero disponible.
  defp valid_method(nil, _service, method), do: method

  defp valid_method(proto, service, method) do
    methods = Proto.methods_for(proto, service)

    cond do
      Enum.any?(methods, &(&1.name == method)) -> method
      methods != [] -> hd(methods).name
      true -> method
    end
  end

  defp parse_kv_rows(rows) do
    rows
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, row} ->
      %{key: row["key"] || "", value: row["value"] || "", enabled: row["enabled"] == "true"}
    end)
  end
end
