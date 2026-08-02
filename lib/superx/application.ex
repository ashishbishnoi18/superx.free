defmodule SuperX.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      SuperXWeb.Telemetry,
      SuperX.Repo,
      {DNSCluster, query: Application.get_env(:superx, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: SuperX.PubSub},
      # Runs LLM calls off the LiveView process so the UI stays responsive.
      {Task.Supervisor, name: SuperX.TaskSupervisor},
      SuperXWeb.ApiRateLimit,
      # Serialises every twitterapi.io call behind one clock, because the
      # plan's QPS is shared across the whole node.
      SuperX.TwitterAPI,
      {Oban, Application.fetch_env!(:superx, Oban)},
      # Start to serve requests, typically the last entry
      SuperXWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SuperX.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SuperXWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
