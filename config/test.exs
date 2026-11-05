import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :xeba, Xeba.Repo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("POSTGRES_HOST", "localhost"),
  port: String.to_integer(System.get_env("POSTGRES_PORT", "5432")),
  database:
    "#{System.get_env("POSTGRES_TEST_DB", "xeba_test")}#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size:
    String.to_integer(
      System.get_env("POSTGRES_POOL_SIZE", Integer.to_string(System.schedulers_online() * 2))
    )

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :xeba, XebaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "lzQWVFkt2WA7ks5CDWXYSShz58jCl/W7fItacPGPX7i+386WFXRFQpNOLox1aA4y",
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

config :xeba, Xeba.Telegram.Poller, enabled: false
