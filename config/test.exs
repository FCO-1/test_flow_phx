import Config

# Test-only DDD wiring: use the in-memory fake HTTP executor so unit
# tests never touch the network. Tests can `FakeHttpExecutor.stage/1`
# the response they want.
config :test_flow_phx,
  http_executor: TestFlowPhx.Support.FakeHttpExecutor,
  grpc_executor: TestFlowPhx.Support.FakeGrpcExecutor,
  # Tests start the JsonFileRepo on demand via start_supervised! with a
  # temp dir, so the global app supervisor must NOT start one.
  start_storage: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :test_flow_phx, TestFlowPhxWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "kF97LgX+pyVbPvBB69SRV/LeILsXX2skx7GMqT93XjEHbHUB6j8zteZ6W3IwmfpK",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
