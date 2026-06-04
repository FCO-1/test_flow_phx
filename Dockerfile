# syntax=docker/dockerfile:1
#
# TestFlow — imagen Docker (web + Docker). Release de producción multi-stage.
#
#  - Stage `builder`: imagen oficial hexpm (elixir+erlang sobre Debian). Baja deps,
#    compila, construye los assets (tailwind+esbuild minificados + digest) y arma
#    un `mix release`.
#  - Stage `runner`: Debian slim + `protoc` (lo usa el motor gRPC en runtime) +
#    libs del runtime de Erlang. Copia solo el release. Arranca el server.
#
# Las versiones van como ARG para ajustarlas si un tag no existe (ver .tool-versions:
# elixir 1.18.0 / erlang 27.0). Si `docker build` falla al hacer pull, cambiá el
# sufijo de fecha de DEBIAN_VERSION por uno publicado en hub.docker.com/r/hexpm/elixir.

ARG ELIXIR_VERSION=1.18.0
ARG OTP_VERSION=27.2.4
ARG DEBIAN_VERSION=bookworm-20260518-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
# Runner usa un tag estable de Debian (no dated) para no depender de una fecha
# concreta; debe ser la MISMA familia que el builder (bookworm) por compatibilidad
# de glibc con el release.
ARG RUNNER_IMAGE="debian:bookworm-slim"

# ===================== Stage 1: builder =====================
FROM ${BUILDER_IMAGE} AS builder

# git → la dep heroicons se baja de GitHub; build-essential por si alguna NIF compila.
RUN apt-get update -y \
  && apt-get install -y build-essential git \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Hex/Rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Deps primero (capa cacheable): copiamos mix.exs/lock y bajamos SOLO prod.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Config de compile-time (config.exs + prod.exs) antes de compilar deps.
COPY config/config.exs config/prod.exs config/
RUN mix deps.compile

# Código + assets
COPY priv priv
COPY lib lib
COPY assets assets

# Assets: baja los binarios de tailwind/esbuild y construye minificado + digest.
RUN mix assets.setup
RUN mix assets.deploy

# Compila la app y arma el release.
RUN mix compile
COPY config/runtime.exs config/
RUN mix release

# ===================== Stage 2: runner =====================
FROM ${RUNNER_IMAGE} AS runner

# protoc → REQUISITO del motor gRPC en runtime (System.find_executable("protoc")).
# Resto: libs del runtime de Erlang + locales UTF-8 + CA certs.
RUN apt-get update -y \
  && apt-get install -y \
       protobuf-compiler \
       libstdc++6 openssl libncurses6 locales ca-certificates \
  && apt-get clean && rm -rf /var/lib/apt/lists/*

# Locale UTF-8 (Elixir lo necesita para manejar binarios correctamente).
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app

# Datos persistentes (colecciones, proto-sets, historial) → volumen.
ENV TEST_FLOW_DATA_DIR=/data
# Arranca el endpoint web del release (runtime.exs lo habilita con PHX_SERVER).
ENV PHX_SERVER=true

# Usuario no-root dueño de /app y /data.
RUN useradd --create-home app \
  && mkdir -p /data \
  && chown -R app:app /app /data
USER app

# Copia el release construido.
COPY --from=builder --chown=app:app /app/_build/prod/rel/test_flow_phx ./

VOLUME ["/data"]

# El puerto real lo fija PORT (env, default 4100 en runtime.exs). Documentado;
# el binding host:container lo hace docker-compose desde .env.
EXPOSE 4100

ENTRYPOINT ["/app/bin/test_flow_phx"]
CMD ["start"]
