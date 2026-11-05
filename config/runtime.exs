import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/xeba start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :xeba, XebaWeb.Endpoint, server: true
end

config :xeba, XebaWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() != :test do
  config :xeba, Xeba.Telegram.Poller,
    base_url: System.get_env("EXIRON_BASE_URL"),
    hook_token: System.get_env("EXIRON_HOOK_TOKEN"),
    client_id: System.get_env("EXIRON_CLIENT_ID", "xeba"),
    ai_endpoint: System.get_env("AI_ENDPOINT"),
    ai_api_key: System.get_env("AI_API_KEY"),
    model: System.get_env("AI_MODEL"),
    bot_name: System.get_env("TELEGRAM_BOT_NAME", "xeba")
end

auth_credentials =
  for {key, variable, default} <- [
        {:username, "XEBA_AUTH_USERNAME", "admin"},
        {:password, "XEBA_AUTH_PASSWORD", "xeba"}
      ] do
    value = System.get_env(variable, if(config_env() == :prod, do: "", else: default))

    if String.trim(value) == "" do
      raise "environment variable #{variable} must be set and non-blank"
    end

    {key, value}
  end

config :xeba, XebaWeb.UserAuth, auth_credentials

if config_env() == :prod do
  # Try to use DATABASE_URL first, fall back to host/port env vars
  database_config =
    case System.get_env("DATABASE_URL") do
      value when value in [nil, ""] ->
        host = System.get_env("POSTGRES_HOST") || "localhost"
        port = String.to_integer(System.get_env("POSTGRES_PORT") || "5432")
        user = System.get_env("POSTGRES_USER") || "postgres"
        password = System.get_env("POSTGRES_PASSWORD") || "postgres"
        db = System.get_env("POSTGRES_DB") || "xeba_dev"

        [hostname: host, port: port, username: user, password: password, database: db]

      database_url ->
        [url: database_url]
    end

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :xeba,
         Xeba.Repo,
         database_config ++
           [
             pool_size:
               String.to_integer(
                 System.get_env("POSTGRES_POOL_SIZE") || System.get_env("POOL_SIZE") || "10"
               ),
             socket_options: maybe_ipv6
           ]

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :xeba, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :xeba, XebaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # HTTPS terminates at a trusted reverse proxy. Production redirects, proxy
  # protocol handling, and HSTS are configured at compile time in prod.exs.
end
