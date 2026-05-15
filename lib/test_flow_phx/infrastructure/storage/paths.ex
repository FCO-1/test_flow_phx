defmodule TestFlowPhx.Infrastructure.Storage.Paths do
  @moduledoc """
  Infrastructure: resolves the on-disk location of the storage file.

  Defaults to `<project_root>/data/` so the directory ships with the repo
  (tracked via `data/.gitkeep`) but the actual `data.json` is git-ignored.
  Honors `TEST_FLOW_DATA_DIR` so tests can stay hermetic.
  """

  @spec data_dir() :: Path.t()
  def data_dir do
    case System.get_env("TEST_FLOW_DATA_DIR") do
      dir when is_binary(dir) and dir != "" -> dir
      _ -> Path.join(File.cwd!(), "data")
    end
  end

  @spec data_file() :: Path.t()
  def data_file, do: Path.join(data_dir(), "data.json")
end
