defmodule TestFlowPhx.Infrastructure.Storage.Paths do
  @moduledoc """
  Infrastructure: resolves the on-disk location of the storage file.

  Honors `TEST_FLOW_DATA_DIR` so tests can stay hermetic. Falls back to
  `~/.config/test_flow` or `/tmp/test_flow` when no home directory is set.
  """

  @spec data_dir() :: Path.t()
  def data_dir do
    case System.get_env("TEST_FLOW_DATA_DIR") do
      dir when is_binary(dir) and dir != "" ->
        dir

      _ ->
        case System.user_home() do
          nil -> Path.join("/tmp", "test_flow")
          home -> Path.join([home, ".config", "test_flow"])
        end
    end
  end

  @spec data_file() :: Path.t()
  def data_file, do: Path.join(data_dir(), "data.json")
end
