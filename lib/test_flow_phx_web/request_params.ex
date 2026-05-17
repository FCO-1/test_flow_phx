defmodule TestFlowPhxWeb.RequestParams do
  @moduledoc """
  Traductor de la capa web entre params de formulario Phoenix (mapas
  anidados con llaves string) y structs `TestFlowPhx.Domain.Request`.

  Vive en el límite web; funciones puras, sin I/O. Siempre hace fallback
  al request `base` para campos que el formulario omite (ej. cuando un
  sub-tab no está renderizado sus inputs no están en el DOM y
  `phx-change` no los incluye).
  """

  alias TestFlowPhx.Domain.Request

  @methods ~w(GET POST PUT PATCH DELETE HEAD OPTIONS)
  @body_types ~w(none json raw form_urlencoded multipart)
  @auth_types ~w(none bearer api_key)
  @auth_locations ~w(header query)
  @row_types ~w(text file)

  @spec from_form(map(), Request.t()) :: Request.t()
  def from_form(params, %Request{} = base) when is_map(params) do
    %{
      base
      | method: parse_method(params["method"], base.method),
        url: params["url"] || base.url,
        body_type: parse_atom(params["body_type"], @body_types, base.body_type),
        body_text: params["body_text"] || base.body_text,
        body_form: parse_form_rows(params["body_form"]) || base.body_form,
        query_params: parse_rows(params["query_params"]) || base.query_params,
        headers: parse_rows(params["headers"]) || base.headers,
        auth: parse_auth(params["auth"], base.auth)
    }
  end

  defp parse_method(m, _default) when is_binary(m) and m != "" do
    if m in @methods, do: m, else: m
  end

  defp parse_method(_, default), do: default

  defp parse_rows(nil), do: nil

  defp parse_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {k, _} -> parse_index(k) end)
    |> Enum.map(fn {_, r} ->
      %{
        key: r["key"] || "",
        value: r["value"] || "",
        enabled: parse_bool(r["enabled"])
      }
    end)
  end

  defp parse_rows(_), do: nil

  defp parse_form_rows(nil), do: nil

  defp parse_form_rows(rows) when is_map(rows) do
    rows
    |> Enum.sort_by(fn {k, _} -> parse_index(k) end)
    |> Enum.map(fn {_, r} ->
      %{
        key: r["key"] || "",
        value: r["value"] || "",
        enabled: parse_bool(r["enabled"]),
        type: parse_atom(r["type"], @row_types, :text),
        file_path: r["file_path"] || nil
      }
    end)
  end

  defp parse_form_rows(_), do: nil

  defp parse_index(k) when is_binary(k), do: String.to_integer(k)
  defp parse_index(k) when is_integer(k), do: k
  defp parse_index(_), do: 0

  defp parse_auth(nil, base), do: base

  defp parse_auth(map, _base) when is_map(map) do
    case parse_atom(map["type"], @auth_types, :none) do
      :none ->
        %{type: :none}

      :bearer ->
        %{type: :bearer, token: map["token"] || ""}

      :api_key ->
        %{
          type: :api_key,
          key: map["key"] || "",
          value: map["value"] || "",
          in: parse_atom(map["in"], @auth_locations, :header)
        }
    end
  end

  defp parse_atom(value, whitelist, default) when is_binary(value) do
    if value in whitelist, do: String.to_existing_atom(value), else: default
  end

  defp parse_atom(_, _, default), do: default

  defp parse_bool("true"), do: true
  defp parse_bool(true), do: true
  defp parse_bool(_), do: false
end
