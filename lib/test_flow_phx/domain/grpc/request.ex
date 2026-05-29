defmodule TestFlowPhx.Domain.Grpc.Request do
  @moduledoc """
  Entidad de dominio: borrador de un request gRPC que el usuario edita o por
  enviar. Datos puros + helpers de construcción; sin I/O ni framework.

  El `.proto` es el contrato: `proto_paths` apunta a los archivos a cargar,
  `import_paths` son directorios raíz extra para resolver `import`s (equivale a
  `-I` de protoc; necesario para `.proto` con imports estilo paquete, p. ej.
  `import "donavida/comun/v1/traza.proto"`), `service`/`method` seleccionan la
  RPC, `body_text` es el mensaje de entrada como **JSON** (se convierte al mapa
  de WireCodec en el límite del executor). `metadata` son headers gRPC custom
  (kv). El tipo de RPC (unary vs server streaming) lo dicta el descriptor del
  método, no este struct.
  """

  @type kv_row :: %{key: String.t(), value: String.t(), enabled: boolean()}

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          target: String.t(),
          proto_paths: [String.t()],
          import_paths: [String.t()],
          service: String.t(),
          method: String.t(),
          metadata: [kv_row()],
          body_text: String.t(),
          collection_id: String.t() | nil
        }

  defstruct id: nil,
            name: "Untitled",
            target: "",
            proto_paths: [],
            import_paths: [],
            service: "",
            method: "",
            metadata: [],
            body_text: "",
            collection_id: nil

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ %{}), do: struct(__MODULE__, normalize(attrs))

  @spec new_id() :: String.t()
  def new_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @spec empty_kv() :: kv_row()
  def empty_kv, do: %{key: "", value: "", enabled: true}

  defp normalize(attrs) when is_list(attrs), do: Map.new(attrs)
  defp normalize(attrs) when is_map(attrs), do: attrs
end
