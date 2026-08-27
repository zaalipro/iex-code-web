import Config

# Background database polling cannot own a SQL Sandbox connection before an
# individual test starts its sandbox owner. Dispatcher tests start it under the
# test supervisor after checkout.
config :iex_code, :start_run_dispatcher, false
config :iex_code, :start_kanban_scheduler, false
config :iex_code, :control_plane_telemetry, enabled: false
config :iex_code, :output_artifacts, enabled: false
config :iex_code, :allow_terminal_test_injection, true
config :iex_code, :apply_persisted_resource_policy_on_start, false
# The application-scoped monitor starts before any per-test SQL Sandbox owner.
# Individual restart tests opt in explicitly; production retains fail-closed
# startup reconciliation by default.
config :iex_code, :operation_monitor_reconcile_on_start, false

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :iex_code, IexCode.Repo,
  database: Path.expand("../iex_code_test#{System.get_env("MIX_TEST_PARTITION")}.db", __DIR__),
  pool_size: 1,
  busy_timeout: 60_000,
  ownership_timeout: 120_000,
  timeout: 60_000,
  journal_mode: :wal,
  default_transaction_mode: :immediate,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :iex_code, IexCodeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "FsxfDyD8OJVsLYVDMcJYaL2t40MlUgtTkUke+qSdrSEyiv2CaotkMOCkfxx28v4C",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
