defmodule TestFlowPhx.Infrastructure.Rest.ReqExecutor do
  @moduledoc """
  Adapter de infrastructure que implementa
  `TestFlowPhx.Domain.Ports.HttpExecutor` sobre el cliente HTTP `Req`.

  Puro: no guarda estado de proceso. Nunca lanza excepciones — los
  fallos de red y de parsing se capturan en `Response.error`.
  """

  @behaviour TestFlowPhx.Domain.Ports.HttpExecutor

  alias TestFlowPhx.Domain.{Rest.Request, Rest.Response}

  @default_timeout 30_000

  @impl true
  @spec send(Request.t(), keyword()) :: Response.t()
  def send(%Request{} = req, opts \\ []) do
    case build_request(req) do
      {:ok, built} -> execute(built, opts)
      {:error, error} -> %Response{error: error}
    end
  end

  defp build_request(%Request{} = req) do
    with {:ok, url} <- build_url(req),
         {:ok, body, extra_headers} <- build_body(req) do
      headers = merged_headers(req, extra_headers)

      {:ok,
       %{
         method: method_atom(req.method),
         url: url,
         headers: headers,
         body: body
       }}
    end
  end

  defp build_url(%Request{url: ""}),
    do: {:error, %{type: :invalid_request, message: "URL is required"}}

  defp build_url(%Request{} = req) do
    base_query = enabled_kv(req.query_params)

    auth_query =
      case req.auth do
        %{type: :api_key, in: :query, key: k, value: v} when k != "" -> [{k, v}]
        _ -> []
      end

    all = base_query ++ auth_query

    url =
      case all do
        [] ->
          req.url

        params ->
          sep = if String.contains?(req.url, "?"), do: "&", else: "?"
          req.url <> sep <> URI.encode_query(params)
      end

    {:ok, url}
  end

  defp build_body(%Request{body_type: :none}), do: {:ok, nil, []}

  defp build_body(%Request{body_type: :json, body_text: ""}), do: {:ok, nil, []}

  defp build_body(%Request{body_type: :json, body_text: text}) do
    case Jason.decode(text) do
      {:ok, _} ->
        {:ok, text, [{"content-type", "application/json"}]}

      {:error, %Jason.DecodeError{} = e} ->
        {:error, %{type: :invalid_json, message: Exception.message(e)}}
    end
  end

  defp build_body(%Request{body_type: :raw, body_text: text}),
    do: {:ok, text, []}

  defp build_body(%Request{body_type: :form_urlencoded, body_form: rows}) do
    pairs =
      for r <- rows, r.enabled, r.type == :text, r.key != "" do
        {r.key, r.value}
      end

    {:ok, URI.encode_query(pairs),
     [{"content-type", "application/x-www-form-urlencoded"}]}
  end

  defp build_body(%Request{body_type: :multipart, body_form: rows}) do
    parts =
      Enum.flat_map(rows, fn
        %{enabled: false} ->
          []

        %{key: ""} ->
          []

        %{type: :text, key: k, value: v} ->
          [{k, v}]

        %{type: :file, key: k, file_path: path} when is_binary(path) and path != "" ->
          [{k, {:file, path}}]

        _ ->
          []
      end)

    {:ok, {:multipart, parts}, []}
  end

  defp merged_headers(%Request{} = req, extra) do
    user = enabled_kv(req.headers)

    auth =
      case req.auth do
        %{type: :bearer, token: t} when t != "" ->
          [{"authorization", "Bearer " <> t}]

        %{type: :api_key, in: :header, key: k, value: v} when k != "" ->
          [{k, v}]

        _ ->
          []
      end

    user_keys = MapSet.new(Enum.map(user, fn {k, _} -> String.downcase(k) end))

    extra_filtered =
      Enum.reject(extra, fn {k, _} -> String.downcase(k) in user_keys end)

    auth_filtered =
      Enum.reject(auth, fn {k, _} -> String.downcase(k) in user_keys end)

    user ++ extra_filtered ++ auth_filtered
  end

  defp enabled_kv(rows) do
    for r <- rows, r.enabled, r.key != "" do
      {r.key, r.value}
    end
  end

  defp method_atom(m) when is_binary(m), do: m |> String.downcase() |> String.to_atom()

  defp execute(%{method: method, url: url, headers: headers, body: body}, opts) do
    timeout = Keyword.get(opts, :receive_timeout, @default_timeout)

    req_opts = [
      method: method,
      url: url,
      headers: headers,
      receive_timeout: timeout,
      decode_body: false,
      retry: false
    ]

    req_opts = if is_nil(body), do: req_opts, else: Keyword.put(req_opts, :body, body)

    started = System.monotonic_time(:millisecond)

    result =
      try do
        Req.request(req_opts)
      rescue
        e -> {:error, e}
      catch
        :exit, reason -> {:error, {:exit, reason}}
      end

    duration = System.monotonic_time(:millisecond) - started
    to_response(result, duration)
  end

  defp to_response({:ok, %Req.Response{} = r}, duration) do
    body = r.body || ""
    headers = normalize_headers(r.headers)
    {decoded, _} = maybe_decode_json(body, headers)

    %Response{
      status: r.status,
      headers: headers,
      body: body,
      body_decoded: decoded,
      duration_ms: duration,
      size_bytes: byte_size_safe(body),
      error: nil
    }
  end

  defp to_response({:error, error}, duration) do
    %Response{error: classify_error(error), duration_ms: duration}
  end

  defp classify_error(%{__exception__: true} = e) do
    msg = Exception.message(e)
    type = if msg =~ ~r/timeout/i, do: :timeout, else: :network
    %{type: type, message: msg}
  end

  defp classify_error({:exit, reason}),
    do: %{type: :unknown, message: inspect(reason)}

  defp classify_error(other),
    do: %{type: :unknown, message: inspect(other)}

  defp normalize_headers(headers) when is_map(headers) do
    Enum.flat_map(headers, fn {k, vs} ->
      Enum.map(List.wrap(vs), fn v -> {String.downcase(to_string(k)), to_string(v)} end)
    end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    Enum.map(headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
  end

  defp maybe_decode_json(body, headers) when is_binary(body) and body != "" do
    ct =
      Enum.find_value(headers, "", fn
        {"content-type", v} -> v
        _ -> nil
      end)

    if ct && String.contains?(String.downcase(ct), "json") do
      case Jason.decode(body) do
        {:ok, term} -> {term, nil}
        {:error, _} -> {nil, nil}
      end
    else
      {nil, nil}
    end
  end

  defp maybe_decode_json(_body, _headers), do: {nil, nil}

  defp byte_size_safe(bin) when is_binary(bin), do: byte_size(bin)
  defp byte_size_safe(_), do: 0
end
