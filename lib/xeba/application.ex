defmodule Xeba.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      XebaWeb.Telemetry,
      XebaWeb.LoginRateLimiter,
      Xeba.Repo,
      {DNSCluster, query: Application.get_env(:xeba, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Xeba.PubSub},
      {Xeba.Telegram.Supervisor, []},
      # Start to serve requests, typically the last entry
      XebaWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Xeba.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    XebaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
