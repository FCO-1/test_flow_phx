# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :test_flow_phx,
  generators: [timestamp_type: :utc_datetime]

# DDD port wiring: bind domain port behaviours to their infrastructure adapters.
# Use cases resolve these at runtime so the domain stays library-agnostic.
config :test_flow_phx,
  http_executor: TestFlowPhx.Infrastructure.Rest.ReqExecutor,
  request_repo: TestFlowPhx.Infrastructure.Storage.JsonFileRepo

# Configures the endpoint
config :test_flow_phx, TestFlowPhxWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TestFlowPhxWeb.ErrorHTML, json: TestFlowPhxWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: TestFlowPhx.PubSub,
  live_view: [signing_salt: "sH0HaC9R"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.17.11",
  test_flow_phx: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.3",
  test_flow_phx: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
