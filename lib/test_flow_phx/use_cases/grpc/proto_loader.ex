defmodule TestFlowPhx.UseCases.Grpc.ProtoLoader do
  @moduledoc """
  Carga uno o más `.proto` y los convierte en metadata estructurada, sin
  codegen: hace shell-out a `protoc --descriptor_set_out`, decodifica el
  `FileDescriptorSet` con la dep `protobuf` y extrae services/methods +
  un registry de mensajes por FQN.

  ## Salida de `load/2`

      {:ok, %{
        files: [%{name: "svc.proto", package: "svc"}],
        services: [%{
          name: "svc.Greeter",                       # FQN estilo path gRPC, sin punto inicial
          methods: [%{
            name: "Unary",
            input_type: ".svc.Req",                   # FQN con punto: indexa messages_by_name
            output_type: ".svc.Resp",
            server_streaming?: false,
            client_streaming?: false
          }]
        }],
        messages_by_name: %{".svc.Req" => %Google.Protobuf.DescriptorProto{}, ...},
        enums_by_name:    %{".svc.Color" => %Google.Protobuf.EnumDescriptorProto{}, ...}
      }}

  `messages_by_name` es exactamente el `registry` que consume
  `TestFlowPhx.Infrastructure.Grpc.WireCodec` (incluye mensajes anidados y los
  entries sintéticos de los maps).

  ## Cache

  Resultado cacheado por SHA256 del contenido concatenado de los `.proto`
  (en `:persistent_term`). Cambiar el contenido invalida la entrada. `load/2`
  acepta `cache: false` para saltarlo y `clear_cache/0` lo vacía.

  ## Prerrequisito

  `protoc` en el PATH (ver README). proto3 con `optional` requiere protoc 3.15+.

  ## Regla de acoplamiento

  Use case del protocolo gRPC. Devuelve estructuras genéricas (mapas +
  descriptores de la dep `protobuf`), sin tipos del domain de TestFlow.
  """

  alias Google.Protobuf.FileDescriptorSet

  @cache_tag {__MODULE__, :cache}

  @type method :: %{
          name: String.t(),
          input_type: String.t(),
          output_type: String.t(),
          server_streaming?: boolean(),
          client_streaming?: boolean()
        }
  @type service :: %{name: String.t(), methods: [method()]}
  @type descriptor :: %{
          files: [%{name: String.t(), package: String.t()}],
          services: [service()],
          messages_by_name: %{optional(String.t()) => Google.Protobuf.DescriptorProto.t()},
          enums_by_name: %{optional(String.t()) => Google.Protobuf.EnumDescriptorProto.t()}
        }

  @doc """
  Carga los `.proto` en `paths`. Opts: `cache: false`, `protoc_runner: fun`
  (inyectable para tests; por defecto corre `protoc` real).
  """
  @spec load([Path.t()], keyword()) :: {:ok, descriptor()} | {:error, String.t()}
  def load(paths, opts \\ []) when is_list(paths) do
    with :ok <- validate(paths) do
      do_load(paths, opts)
    end
  end

  @doc "Vacía el cache de descriptores."
  @spec clear_cache() :: :ok
  def clear_cache do
    Enum.each(:persistent_term.get(), fn
      {{@cache_tag, _sha} = k, _v} -> :persistent_term.erase(k)
      _ -> :ok
    end)
  end

  @doc """
  Convierte la salida (stderr) de protoc en un mensaje legible. Añade una pista
  cuando el error huele a la limitación de `optional` en protoc < 3.15.
  """
  @spec format_error(String.t()) :: String.t()
  def format_error(output) do
    msg = output |> String.trim() |> String.replace(~r/\n{2,}/, "\n")
    low = String.downcase(msg)

    if String.contains?(low, "optional") and String.contains?(low, "proto3") do
      msg <> "\n\n(pista: proto3 con `optional` requiere protoc 3.15+; revisá `protoc --version`)"
    else
      msg
    end
  end

  # ── interno ─────────────────────────────────────────────────────────────────

  defp validate([]), do: {:error, "no se especificaron archivos .proto"}

  defp validate(paths) do
    case Enum.find(paths, &(not File.exists?(&1))) do
      nil -> :ok
      missing -> {:error, "archivo .proto no encontrado: #{missing}"}
    end
  end

  defp do_load(paths, opts) do
    use_cache = Keyword.get(opts, :cache, true)
    runner = Keyword.get(opts, :protoc_runner, &run_protoc/1)
    key = cache_key(paths)

    case use_cache && cache_get(key) do
      {:ok, desc} ->
        {:ok, desc}

      _ ->
        case runner.(paths) do
          {:ok, set} ->
            desc = build(set)
            if use_cache, do: :persistent_term.put({@cache_tag, key}, desc)
            {:ok, desc}

          {:error, _} = err ->
            err
        end
    end
  end

  defp cache_get(key) do
    case :persistent_term.get({@cache_tag, key}, :miss) do
      :miss -> :miss
      desc -> {:ok, desc}
    end
  end

  defp cache_key(paths) do
    contents = paths |> Enum.sort() |> Enum.map_join("\0", &File.read!/1)
    :crypto.hash(:sha256, contents) |> Base.encode16()
  end

  defp run_protoc(paths) do
    cond do
      System.find_executable("protoc") == nil ->
        {:error, "protoc no está en el PATH. Instalá Protocol Buffers (ver README)."}

      true ->
        tmp = Path.join(System.tmp_dir!(), "tf_grpc_#{:erlang.unique_integer([:positive])}.desc")
        includes = paths |> Enum.map(&Path.dirname/1) |> Enum.uniq()
        args = ["--include_imports", "--descriptor_set_out=#{tmp}"] ++
                 Enum.flat_map(includes, &["-I", &1]) ++ paths

        try do
          case System.cmd("protoc", args, stderr_to_stdout: true) do
            {_out, 0} -> {:ok, tmp |> File.read!() |> FileDescriptorSet.decode()}
            {out, _code} -> {:error, format_error(out)}
          end
        after
          File.rm(tmp)
        end
    end
  end

  defp build(%FileDescriptorSet{file: files}) do
    %{
      files: Enum.map(files, &%{name: &1.name, package: &1.package || ""}),
      services: Enum.flat_map(files, fn f -> Enum.map(f.service, &build_service(&1, f.package)) end),
      messages_by_name:
        Enum.reduce(files, %{}, fn f, acc -> collect_messages(prefix(f), f.message_type, acc) end),
      enums_by_name:
        Enum.reduce(files, %{}, fn f, acc ->
          collect_enums(prefix(f), f.enum_type, f.message_type, acc)
        end)
    }
  end

  defp prefix(f), do: if(f.package in [nil, ""], do: "", else: "." <> f.package)

  defp build_service(svc, package) do
    name = if package in [nil, ""], do: svc.name, else: package <> "." <> svc.name

    methods =
      Enum.map(svc.method, fn m ->
        %{
          name: m.name,
          input_type: m.input_type,
          output_type: m.output_type,
          server_streaming?: m.server_streaming,
          client_streaming?: m.client_streaming
        }
      end)

    %{name: name, methods: methods}
  end

  defp collect_messages(prefix, msgs, acc) do
    Enum.reduce(msgs, acc, fn m, acc ->
      fqn = prefix <> "." <> m.name
      collect_messages(fqn, m.nested_type, Map.put(acc, fqn, m))
    end)
  end

  defp collect_enums(prefix, enums, msgs, acc) do
    acc = Enum.reduce(enums, acc, fn e, acc -> Map.put(acc, prefix <> "." <> e.name, e) end)

    Enum.reduce(msgs, acc, fn m, acc ->
      fqn = prefix <> "." <> m.name
      collect_enums(fqn, m.enum_type, m.nested_type, acc)
    end)
  end
end
