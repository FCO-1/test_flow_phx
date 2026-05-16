defmodule TestFlowPhx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        TestFlowPhxWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:test_flow_phx, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: TestFlowPhx.PubSub},
        {Task.Supervisor, name: TestFlowPhx.TaskSupervisor}
      ] ++
        storage_children() ++
        [
          # Start to serve requests, typically the last entry
          TestFlowPhxWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: TestFlowPhx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Storage is wired in via config so test env can opt out and start the
  # GenServer on demand inside each test with its own temp data dir.
  defp storage_children do
    if Application.get_env(:test_flow_phx, :start_storage, true) do
      [TestFlowPhx.Infrastructure.Storage.JsonFileRepo]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TestFlowPhxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
