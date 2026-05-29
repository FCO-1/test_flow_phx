defmodule TestFlowPhx.UseCases.Variables do
  @moduledoc """
  Resolución de plantillas `{{var}}` en strings y requests.

  Las variables son puras (`%{name, value, enabled}`); este módulo no
  habla con el repo. La capa que envía un request es la responsable de
  recolectar las vars activas (globales ∪ vars de la colección de la
  tab) y pasárselas a `resolve_request/2`.

  ## Precedencia

  `merge(globals, collection_vars)` devuelve un mapa donde las llaves
  duplicadas las gana la colección. Las vars con `enabled: false` o
  `name: ""` se descartan en `merge`.

  ## Vars faltantes

  Si una plantilla referencia una variable que no existe en el mapa, se
  deja el placeholder literal (`"{{missing}}"`). Es debug visual: si veo
  esa cadena en el request enviado, sé que olvidé definir la var. Mejor
  que sustituir por string vacío y enviar algo mal-formado en silencio.
  """

  alias TestFlowPhx.Domain.{Collection, Rest.Request}

  @placeholder ~r/\{\{([A-Za-z0-9_]+)\}\}/

  @type variable :: Collection.variable()
  @type vars_map :: %{String.t() => String.t()}

  @doc "Fila vacía para sembrar editores de variables en UI."
  @spec empty() :: variable()
  def empty, do: %{name: "", value: "", enabled: true}

  @doc """
  Combina globales con vars de colección en un mapa `name => value`.

  Precedencia: colección > global. Descarta filas con `enabled: false`
  o con `name` vacío (después de trim).
  """
  @spec merge([variable()], [variable()]) :: vars_map()
  def merge(globals, collection_vars)
      when is_list(globals) and is_list(collection_vars) do
    globals
    |> to_map()
    |> Map.merge(to_map(collection_vars))
  end

  @doc "Sustituye `{{var}}` en un string. Vars faltantes quedan literal."
  @spec resolve(String.t(), vars_map()) :: String.t()
  def resolve(string, vars) when is_binary(string) and is_map(vars) do
    Regex.replace(@placeholder, string, fn full, name ->
      Map.get(vars, name, full)
    end)
  end

  def resolve(other, _vars), do: other

  @doc """
  Aplica `resolve/2` sobre todos los campos string visibles de un
  request: URL, query values, header values, body_text, form values, y
  los campos de auth. NO toca `file_path` (esa es una ruta del sistema,
  no una plantilla del usuario).
  """
  @spec resolve_request(Request.t(), vars_map()) :: Request.t()
  def resolve_request(%Request{} = req, vars) when is_map(vars) do
    %Request{
      req
      | url: resolve(req.url, vars),
        query_params: resolve_kv_rows(req.query_params, vars),
        headers: resolve_kv_rows(req.headers, vars),
        body_text: resolve(req.body_text, vars),
        body_form: resolve_form_rows(req.body_form, vars),
        auth: resolve_auth(req.auth, vars)
    }
  end

  # ----- Private -----

  defp to_map(vars) do
    Enum.reduce(vars, %{}, fn
      %{enabled: false}, acc ->
        acc

      %{name: name, value: value}, acc ->
        case String.trim(to_string(name)) do
          "" -> acc
          trimmed -> Map.put(acc, trimmed, to_string(value))
        end

      _, acc ->
        acc
    end)
  end

  defp resolve_kv_rows(rows, vars) do
    Enum.map(rows, fn row -> %{row | value: resolve(row.value, vars)} end)
  end

  defp resolve_form_rows(rows, vars) do
    Enum.map(rows, fn row -> %{row | value: resolve(row.value, vars)} end)
  end

  defp resolve_auth(%{type: :none} = auth, _vars), do: auth

  defp resolve_auth(%{type: :bearer, token: token} = auth, vars),
    do: %{auth | token: resolve(token, vars)}

  defp resolve_auth(%{type: :api_key, key: k, value: v} = auth, vars),
    do: %{auth | key: resolve(k, vars), value: resolve(v, vars)}

  defp resolve_auth(other, _vars), do: other
end
