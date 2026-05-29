defmodule TestFlowPhx.Domain.Grpc.ProtoSet do
  @moduledoc """
  Entidad de dominio: un **proto-set** es un bundle nombrado de archivos `.proto`
  (el árbol completo, preservando la estructura de imports) guardado en disco
  bajo `data/grpc/proto_sets/<id>/`. Su directorio ES el `import_root`: las
  rutas de `import "..."` se resuelven relativas a él.

  Un `.proto` suelto (sin imports) es simplemente un proto-set de un archivo.

  Campos:

    * `id` — identificador local (nombre de la carpeta en disco).
    * `name` — nombre legible/portable (lo que viaja en el export; sirve para
      re-enlazar requests importados con un set local).
    * `entry_files` — `.proto` que definen `service`s (los que el usuario llama),
      como rutas **relativas** al `import_root`.
    * `files` — todas las rutas relativas del set (para mostrar/depurar).
    * `created_ms` — epoch ms de creación.

  Datos puros; sin I/O. La carga/validación/almacenamiento vive en
  `TestFlowPhx.UseCases.Grpc.GrpcProtoSets`.
  """

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t(),
          entry_files: [String.t()],
          files: [String.t()],
          created_ms: integer() | nil
        }

  defstruct id: nil, name: "", entry_files: [], files: [], created_ms: nil

  @spec new_id() :: String.t()
  def new_id, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
end
