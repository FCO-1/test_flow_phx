# TestFlow

Alternativa local a Postman/Insomnia construida en Phoenix LiveView. Single-user, sin SaaS, sin suscripciones — los datos viven en `data/` junto al proyecto y se versionan localmente.

## Estado

Fase 1 completa (REST):

- Multi-tab workspace con response per-tab (cambiar de tab no pierde la response in-flight de otro).
- Colecciones con sidebar (crear/expand/rename inline/borrar) + modal "Save" para guardar la request actual a una colección existente o nueva.
- History persistente: cada send escribe el body de la response a `data/rest/<YYYY-MM-DD>/<epoch_ms>.<ext>` y appendea un `HistoryEntry`. Click en una entrada del historial la reabre como tab.
- 5 tipos de body: `none`, `json` (con Format), `raw`, `form-urlencoded` (kv editor), `multipart` (text/file rows; la ruta del archivo se escribe como string).
- Auth Bearer + API Key (header o query).
- Tabs y workspace persisten en `data/state.json` — un reload del navegador restaura el estado.

Fuera de Fase 1 (futuro): GraphQL/WebSocket/gRPC, multi-usuario, variables `{{base_url}}`, carpetas anidadas, SQLite adapter, UI real de upload con `allow_upload/3`.

## Stack

- Phoenix 1.7 / LiveView 1.1 (sin Ecto, sin DaisyUI, sin toolchain JS extra)
- `Req ~> 0.5` como cliente HTTP
- `Jason` para JSON
- Tailwind para estilos
- Persistencia: archivo JSON local (`data/state.json`) con `GenServer` debounced + write atómico (`.tmp` + `rename`)

## Arquitectura (DDD por capas)

Cada capa se subdivide **por protocolo** (`rest/`, `grpc/`) para mantener el
orden a medida que se agregan protocolos. Lo transversal (Collection, History,
Globals, Variables, Storage, ports) vive en la raíz de su capa.

```
lib/test_flow_phx/
  domain/
    rest/           # Request, Response
    grpc/           # GrpcRequest, GrpcResponse (Fase N)
    ports/          # behaviours: HttpExecutor, RequestRepo, GrpcExecutor
    collection.ex   history_entry.ex          # transversales
  use_cases/
    rest/           # SendRequest, CurlExport
    grpc/           # SendGrpcRequest, ProtoLoader (Fase N)
    collections.ex  globals.ex  variables.ex  tabs.ex  …   # transversales
  infrastructure/
    rest/           # ReqExecutor (adapter HttpExecutor sobre Req)
    grpc/           # WireCodec, Frame, Http2Client, Client (cliente propio) + adapter
    storage/        # JsonFileRepo, Serializer, Paths                # transversal
  smoke/
    rest/           # smokes manuales REST con [PASS]/[FAIL] estilo iex
    storage.ex  tabs.ex  web_shell.ex                       # transversales
lib/test_flow_phx_web/
  live/             # LiveViews (RestLive montada en /)
  components/       # function components stateless
  request_params.ex # form params → %Domain.Rest.Request{} (web boundary)
```

El motor gRPC bajo `infrastructure/grpc/` se diseña **sin acoplarse** a TestFlow
(cero refs a domain/otra infra; I/O genérico), para poder extraerlo a una lib
propia si crece.

El dominio nunca importa infraestructura. Los use cases resuelven el adapter en runtime con `Application.fetch_env!(:test_flow_phx, :http_executor | :request_repo)`, lo que permite swap-ear en tests por un fake (ver `test/support/fake_http_executor.ex`).

## Prerrequisitos

- Elixir / Erlang (ver `mix.exs`).
- **`protoc` en el PATH** (Protocol Buffers compiler) — requerido por la sección
  gRPC para parsear `.proto` a un `FileDescriptorSet`. Mínimo recomendado 3.15+;
  con 3.12 los `.proto` que usen `optional` en proto3 fallarán al compilar.
  Verificar con `protoc --version`. En Debian/Ubuntu: `apt install protobuf-compiler`.

## Correr en local

```bash
mix setup                    # deps + assets
iex -S mix phx.server        # arranca con shell — http://localhost:4000
```

Override del directorio de datos:

```bash
TEST_FLOW_DATA_DIR=/tmp/tf iex -S mix phx.server
```

## Layout de `data/`

```
data/
  state.json                       # colecciones + tabs + history (index)
  rest/                            # un dir por protocolo
    2026-05-15/                    # ISO date
      1715812345678.json           # body de cada send (extensión por content-type)
```

La carpeta `data/` se trackea vacía via `.gitkeep`; el contenido está git-ignored.

## Tests

```bash
mix test                                                          # suite completa
mix test test/test_flow_phx_web/live/tester_live_test.exs         # solo LiveView
```

`test/test_helper.exs` redirige `TEST_FLOW_DATA_DIR` a `/tmp/` para aislar la suite del working tree.

Los smokes manuales viven en `lib/test_flow_phx/smoke/` y se corren desde `iex -S mix`:

```elixir
TestFlowPhx.Smoke.HttpExecutor.todos()   # 10 checks contra httpbin.org
TestFlowPhx.Smoke.Storage.todos()        # 17 checks JsonFileRepo (incluye restart-sobrevive)
TestFlowPhx.Smoke.RequestFlow.todos()    # 12 checks parser + send via httpbin
TestFlowPhx.Smoke.Tabs.todos()           # 7 checks tabs persistencia + restart
TestFlowPhx.Smoke.WebShell.todos()       # 7 checks (requiere phx.server arriba)
```

## Licencia

MIT — ver [LICENSE](LICENSE).
