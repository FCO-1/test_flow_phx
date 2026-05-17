defmodule TestFlowPhx.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    apply_persisted_data_dir()

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

  # Aplica el data dir guardado por el usuario (desde
  # ~/.config/test_flow_phx/config.json) antes de que arranque el storage,
  # así el repo abre el state.json correcto.
  defp apply_persisted_data_dir do
    case TestFlowPhx.UseCases.Settings.read_persisted_data_dir() do
      {:ok, dir} -> Application.put_env(:test_flow_phx, :data_dir_override, dir)
      :error -> :ok
    end
  end

  # El storage se cablea vía config para que el test env pueda optar por
  # no incluirlo y cada test arranque el GenServer on-demand con su
  # propio data dir temporal.
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
