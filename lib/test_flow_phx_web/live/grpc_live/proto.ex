defmodule TestFlowPhxWeb.GrpcLive.Proto do
  @moduledoc """
  Helpers puros derivados del descriptor cargado por `ProtoLoader`: extraer
  services/methods para los dropdowns y preseleccionar el método inicial.

  Análogo a cómo `RestLive.RepoHelpers` aísla el acceso a datos fuera del
  `index.ex`. Aquí no hay I/O: solo lectura del mapa de descriptor.
  """

  alias TestFlowPhx.Domain.Grpc.Request

  @doc "Lista de services del descriptor (`[]` si no hay proto)."
  def services(nil), do: []
  def services(proto), do: proto.services

  @doc "Methods del service indicado (`[]` si no existe)."
  def methods_for(nil, _service), do: []

  def methods_for(proto, service) do
    case Enum.find(proto.services, &(&1.name == service)) do
      %{methods: methods} -> methods
      _ -> []
    end
  end

  @doc "Descriptor del method seleccionado, o `nil`."
  def selected_method(proto, service, method) do
    Enum.find(methods_for(proto, service), &(&1.name == method))
  end

  @doc "¿El method seleccionado es server-streaming?"
  def streaming_method?(proto, service, method) do
    match?(%{server_streaming?: true}, selected_method(proto, service, method))
  end

  @doc "Preselecciona el primer service + su primer method del descriptor."
  def preselect(%Request{} = request, desc) do
    with %{name: service, methods: [%{name: method} | _]} <- List.first(desc.services) do
      %{request | service: service, method: method}
    else
      _ -> request
    end
  end
end
