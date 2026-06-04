defmodule TestFlowPhx.UseCases.Rest.CurlExport do
  @moduledoc """
  Builder puro que convierte un `TestFlowPhx.Domain.Rest.Request` en un string
  de comando `curl` listo para pegar en una shell POSIX.

  Espeja el comportamiento de `TestFlowPhx.Infrastructure.Rest.ReqExecutor`
  para que el comando impreso sea exactamente lo que la app enviaría.
  """

  alias TestFlowPhx.Domain.Rest.Request
  alias TestFlowPhx.UseCases.Variables

  @doc """
  Genera el comando `curl` para un request. Si se pasa `vars` (mapa
  `name => value`), resuelve placeholders `{{var}}` antes de imprimir
  — el comando exportado va a una terminal donde las vars no existen,
  así que llevar literales sería inútil.
  """
  @spec from_request(Request.t(), %{String.t() => String.t()}) :: String.t()
  def from_request(%Request{} = req, vars \\ %{}) do
    req = if map_size(vars) == 0, do: req, else: Variables.resolve_request(req, vars)

    parts =
      ["curl"]
      |> append(["-X", req.method])
      |> append(header_args(req))
      |> append(body_args(req))
      |> append([quote_arg(build_url(req))])

    Enum.join(parts, " \\\n  ")
  end

  defp append(acc, []), do: acc
  defp append(acc, more), do: acc ++ [Enum.join(more, " ")]

  defp build_url(%Request{} = req) do
    base = enabled_pairs(req.query_params)

    auth =
      case req.auth do
        %{type: :api_key, in: :query, key: k, value: v} when k != "" -> [{k, v}]
        _ -> []
      end

    case base ++ auth do
      [] ->
        req.url

      pairs ->
        sep = if String.contains?(req.url, "?"), do: "&", else: "?"
        req.url <> sep <> URI.encode_query(pairs)
    end
  end

  defp header_args(%Request{} = req) do
    explicit = enabled_pairs(req.headers)

    auth =
      case req.auth do
        %{type: :bearer, token: t} when t != "" ->
          [{"Authorization", "Bearer " <> t}]

        %{type: :api_key, in: :header, key: k, value: v} when k != "" ->
          [{k, v}]

        _ ->
          []
      end

    content_type =
      case req.body_type do
        :json -> if req.body_text == "", do: [], else: [{"Content-Type", "application/json"}]
        :form_urlencoded -> [{"Content-Type", "application/x-www-form-urlencoded"}]
        _ -> []
      end

    explicit_keys = MapSet.new(Enum.map(explicit, fn {k, _} -> String.downcase(k) end))

    extra =
      (content_type ++ auth)
      |> Enum.reject(fn {k, _} -> String.downcase(k) in explicit_keys end)

    for {k, v} <- explicit ++ extra do
      ~s(-H ) <> quote_arg(k <> ": " <> v)
    end
  end

  defp body_args(%Request{body_type: :none}), do: []
  defp body_args(%Request{body_type: :json, body_text: ""}), do: []

  defp body_args(%Request{body_type: :json, body_text: text}),
    do: ["--data " <> quote_arg(text)]

  defp body_args(%Request{body_type: :raw, body_text: ""}), do: []

  defp body_args(%Request{body_type: :raw, body_text: text}),
    do: ["--data-raw " <> quote_arg(text)]

  defp body_args(%Request{body_type: :form_urlencoded, body_form: rows}) do
    for r <- rows, r.enabled, r.type == :text, r.key != "" do
      "--data-urlencode " <> quote_arg(r.key <> "=" <> r.value)
    end
  end

  defp body_args(%Request{body_type: :multipart, body_form: rows}) do
    Enum.flat_map(rows, fn
      %{enabled: false} ->
        []

      %{key: ""} ->
        []

      %{type: :text, key: k, value: v} ->
        ["-F " <> quote_arg(k <> "=" <> v)]

      %{type: :file, key: k, file_path: path} when is_binary(path) and path != "" ->
        ["-F " <> quote_arg(k <> "=@" <> path)]

      _ ->
        []
    end)
  end

  defp enabled_pairs(rows) do
    for r <- rows, r.enabled, r.key != "", do: {r.key, r.value}
  end

  defp quote_arg(s) when is_binary(s) do
    "'" <> String.replace(s, "'", "'\\''") <> "'"
  end
end
