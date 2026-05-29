defmodule TestFlowPhx.Smoke.Grpc.RequestFlow do
  @moduledoc """
  Smoke test **manual** del flujo gRPC end-to-end contra un servidor real.

  A diferencia de los smoke REST (que apuntan a `httpbin.org`), gRPC necesita
  un servidor gRPC real al que conectar **y** el `.proto` que describe sus
  servicios. Como ese servidor vive en la máquina del usuario (no hay un
  `httpbin` gRPC público y estable), este módulo es **parametrizado**: le pasás
  el `target` (`host:port`) y la ruta al `.proto`, y él ejercita el motor real
  (`ProtoLoader` + `SendGrpcRequest` → adapter `Infrastructure.Grpc.GrpcExecutor`).

  > **Importante**: el cliente gRPC v1 es **plaintext / h2c** (sin TLS). El
  > `target` debe ser un endpoint en claro. Si el servidor exige TLS, la
  > conexión fallará con un error de transporte (esperado en v1).

  ## Cómo usarlo

  Arrancá una IEx con el proyecto cargado (NO hace falta `phx.server`; el smoke
  llama los use cases directo):

      iex -S mix

  ### 1. Descubrir qué hay en el `.proto`

  Primero mirá los servicios/métodos disponibles para saber qué llamar:

      alias TestFlowPhx.Smoke.Grpc.RequestFlow, as: G
      G.discover(proto: "/ruta/al/archivo.proto")

  Imprime cada servicio, sus métodos, el tipo de RPC (unary vs server stream)
  y los mensajes de entrada/salida.

  ### 2. Probar un unary

      G.unary(
        target: "localhost:50051",
        proto: "/ruta/al/archivo.proto",
        service: "paquete.MiServicio",
        method: "MiMetodoUnary",
        body: ~s({"campo": "valor"})
      )

  ### 3. Probar un server streaming

      G.server_stream(
        target: "localhost:50051",
        proto: "/ruta/al/archivo.proto",
        service: "paquete.MiServicio",
        method: "MiMetodoStream",
        body: ~s({"campo": "valor"})
      )

  ### 4. Casos de error (no necesitan que el método exista / el server esté)

      # método inexistente → grpc-status != 0
      G.unknown_method(target: "localhost:50051", proto: "/ruta/al/archivo.proto",
                       service: "paquete.MiServicio")

      # target inválido → error de transporte
      G.bad_target(proto: "/ruta/al/archivo.proto",
                   service: "paquete.MiServicio", method: "MiMetodoUnary")

  ### 5. Todo de corrido

      G.todos(
        target: "localhost:50051",
        proto: "/ruta/al/archivo.proto",
        service: "paquete.MiServicio",
        unary_method: "MiMetodoUnary",
        stream_method: "MiMetodoStream",     # opcional
        unary_body: ~s({"campo": "valor"}),
        stream_body: ~s({"campo": "valor"})
      )

  `todos/1` corre discover + unary + (si das `stream_method`) server stream +
  método inexistente + target inválido, y al final imprime un resumen de checks.

  ## Qué verifica

  Que las piezas reales encajan extremo a extremo: protoc parsea el `.proto`,
  el `WireCodec`/`JsonCodec` serializan el body JSON al wire, el `Http2Client`
  abre la conexión h2c, el `Client` enmarca/desenmarca y lee `grpc-status`, y
  el `Response` del dominio llega armado. Es el camino que los tests automáticos
  ejercitan contra un Bandit h2c local; acá se valida contra un server real
  (incluyendo trailers reales, que Bandit/Plug no emite — ver `client_test`).
  """

  alias TestFlowPhx.Domain.Grpc.Request
  alias TestFlowPhx.UseCases.Grpc.{ProtoLoader, SendGrpcRequest}

  @default_timeout 15_000

  # ---------- Descubrimiento ----------

  @doc """
  Carga el `.proto` y lista servicios + métodos. No conecta a ningún servidor.

      G.discover(proto: "/ruta/al/archivo.proto")
  """
  def discover(opts) do
    proto = fetch!(opts, :proto)
    IO.puts("\n=== DISCOVER: #{proto} ===")

    case load_proto(proto, opts[:import_paths] || []) do
      {:ok, desc} ->
        if desc.services == [] do
          IO.puts("   (el .proto no define servicios)")
        end

        Enum.each(desc.services, fn svc ->
          IO.puts("\n   service #{svc.name}")

          Enum.each(svc.methods, fn m ->
            kind = method_kind(m)
            IO.puts("     rpc #{m.name}  [#{kind}]")
            IO.puts("        in : #{m.input_type}")
            IO.puts("        out: #{m.output_type}")
          end)
        end)

        IO.puts("")
        desc

      {:error, msg} ->
        IO.puts("   ERROR cargando el .proto:\n#{msg}")
        {:error, msg}
    end
  end

  # ---------- Pasos individuales ----------

  @doc "Envía un unary. Ver moduledoc para las opciones."
  def unary(opts) do
    IO.puts("\n=== UNARY: #{opts[:service]}/#{opts[:method]} → #{opts[:target]} ===")

    req =
      build_request(opts,
        target: fetch!(opts, :target),
        service: fetch!(opts, :service),
        method: fetch!(opts, :method),
        body_text: opts[:body] || "{}"
      )

    resp = SendGrpcRequest.execute(req, timeout: opts[:timeout] || @default_timeout)
    render_response(resp)

    record_check("unary sin error", true, is_nil(resp.error))
    record_check("unary grpc-status == 0", 0, resp.status)
    record_check("unary trae body_decoded", true, not is_nil(resp.body_decoded))

    resp
  end

  @doc "Envía un server streaming, imprimiendo cada mensaje a medida que llega."
  def server_stream(opts) do
    IO.puts("\n=== SERVER STREAM: #{opts[:service]}/#{opts[:method]} → #{opts[:target]} ===")

    parent = self()

    req =
      build_request(opts,
        target: fetch!(opts, :target),
        service: fetch!(opts, :service),
        method: fetch!(opts, :method),
        body_text: opts[:body] || "{}"
      )

    resp =
      SendGrpcRequest.execute(req,
        timeout: opts[:timeout] || @default_timeout,
        on_message: fn msg ->
          send(parent, {:smoke_msg, msg})
          IO.inspect(msg, label: "   <<< msg", pretty: true, limit: 5)
        end
      )

    render_response(resp)

    record_check("stream sin error", true, is_nil(resp.error))
    record_check("stream grpc-status == 0", 0, resp.status)
    record_check("stream recibió >= 1 mensaje", true, length(resp.messages || []) >= 1)
    record_check("stream marcado streaming?", true, resp.streaming?)

    resp
  end

  @doc """
  Llama un método que no existe en el servicio → debe devolver grpc-status != 0
  (o un error). No necesita `:method` real.
  """
  def unknown_method(opts) do
    IO.puts("\n=== UNKNOWN METHOD → #{opts[:target]} ===")

    req =
      build_request(opts,
        target: fetch!(opts, :target),
        service: fetch!(opts, :service),
        method: "MetodoQueNoExiste_smoke",
        body_text: "{}"
      )

    resp = SendGrpcRequest.execute(req, timeout: opts[:timeout] || @default_timeout)
    render_response(resp)

    erroneo? = not is_nil(resp.error) or resp.status not in [0, nil]
    record_check("método inexistente reporta error/grpc-status != 0", true, erroneo?)

    resp
  end

  @doc """
  Apunta a un host:puerto inalcanzable → debe devolver un error de transporte.
  Usa `:bad_target` (default `\"127.0.0.1:1\"`).
  """
  def bad_target(opts) do
    target = opts[:bad_target] || "127.0.0.1:1"
    IO.puts("\n=== BAD TARGET (#{target}) ===")

    req =
      build_request(opts,
        target: target,
        service: fetch!(opts, :service),
        method: fetch!(opts, :method),
        body_text: opts[:body] || "{}"
      )

    resp = SendGrpcRequest.execute(req, timeout: opts[:timeout] || 5_000)
    render_response(resp)

    record_check("target inválido devuelve error", true, not is_nil(resp.error))

    resp
  end

  # ---------- Orquestador ----------

  @doc """
  Corre la batería completa. Requiere `:target`, `:proto`, `:service`,
  `:unary_method`. Opcional `:stream_method`, `:unary_body`, `:stream_body`.
  """
  def todos(opts) do
    reset_checks()
    ip = opts[:import_paths] || []
    discover(proto: fetch!(opts, :proto), import_paths: ip)

    unary(
      target: fetch!(opts, :target),
      proto: opts[:proto],
      import_paths: ip,
      service: fetch!(opts, :service),
      method: fetch!(opts, :unary_method),
      body: opts[:unary_body] || "{}",
      timeout: opts[:timeout]
    )

    if opts[:stream_method] do
      server_stream(
        target: opts[:target],
        proto: opts[:proto],
        import_paths: ip,
        service: opts[:service],
        method: opts[:stream_method],
        body: opts[:stream_body] || "{}",
        timeout: opts[:timeout]
      )
    end

    unknown_method(
      target: opts[:target],
      proto: opts[:proto],
      import_paths: ip,
      service: opts[:service]
    )

    bad_target(
      proto: opts[:proto],
      import_paths: ip,
      service: opts[:service],
      method: opts[:unary_method],
      body: opts[:unary_body] || "{}"
    )

    resumen_checks()
  end

  # ---------- Helpers ----------

  # Construye un Grpc.Request con un id fresco, repasando opts -> overrides.
  defp build_request(opts, overrides) do
    Request.new(
      [
        id: Request.new_id(),
        name: "smoke",
        proto_paths: [fetch!(opts, :proto)],
        import_paths: opts[:import_paths] || [],
        metadata: opts[:metadata] || []
      ] ++ overrides
    )
  end

  defp load_proto(proto, import_paths), do: ProtoLoader.load([proto], import_paths: import_paths)

  defp method_kind(%{server_streaming?: true}), do: "server stream"
  defp method_kind(%{client_streaming?: true}), do: "client stream"
  defp method_kind(_), do: "unary"

  defp fetch!(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, val} -> val
      :error -> raise ArgumentError, "falta la opción obligatoria :#{key}"
    end
  end

  defp render_response(resp) do
    if resp.error do
      IO.puts("   ERROR")
      IO.puts("   duration : #{resp.duration_ms} ms")
      IO.inspect(resp.error, label: "   error", pretty: true)
    else
      IO.puts("   grpc-status : #{resp.status}")
      IO.puts("   duration    : #{resp.duration_ms} ms")
      IO.puts("   streaming?  : #{resp.streaming?}")

      cond do
        resp.streaming? ->
          IO.puts("   mensajes    : #{length(resp.messages || [])}")

        resp.body_decoded ->
          IO.inspect(resp.body_decoded, label: "   body_decoded", pretty: true, limit: 5)

        true ->
          :ok
      end
    end
  end

  # ---------- Checks framework (mismo patrón que los smoke REST) ----------

  def reset_checks do
    Process.put(:smoke_checks, [])
    :ok
  end

  def resumen_checks do
    checks = Process.get(:smoke_checks, []) |> Enum.reverse()
    pass = Enum.count(checks, fn %{pass?: p} -> p end)
    fail = length(checks) - pass

    IO.puts("\n\n=== RESUMEN DE CHECKS ===")

    Enum.each(checks, fn %{label: label, expected: exp, actual: act, pass?: pass?} ->
      mark = if pass?, do: "[PASS]", else: "[FAIL]"
      IO.puts("#{mark} #{label}")

      unless pass? do
        IO.puts("       esperado : #{inspect(exp)}")
        IO.puts("       actual   : #{inspect(act)}")
      end
    end)

    IO.puts("\nTotal: #{pass} PASS / #{fail} FAIL (#{length(checks)} checks)")
    %{pass: pass, fail: fail, total: length(checks)}
  end

  defp record_check(label, expected, actual) do
    pass? = expected == actual
    entry = %{label: label, expected: expected, actual: actual, pass?: pass?}
    Process.put(:smoke_checks, [entry | Process.get(:smoke_checks, [])])

    mark = if pass?, do: "[PASS]", else: "[FAIL]"
    IO.puts("   #{mark} #{label}")

    unless pass? do
      IO.puts("          esperado : #{inspect(expected)}")
      IO.puts("          actual   : #{inspect(actual)}")
    end

    :ok
  end
end
