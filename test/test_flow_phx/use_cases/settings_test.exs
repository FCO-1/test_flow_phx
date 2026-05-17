defmodule TestFlowPhx.UseCases.SettingsTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.UseCases.Settings

  setup do
    tmp = Path.join(System.tmp_dir!(), "tf_settings_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    config_file = Path.join(tmp, "config.json")
    System.put_env("TEST_FLOW_CONFIG_FILE", config_file)

    on_exit(fn ->
      System.delete_env("TEST_FLOW_CONFIG_FILE")
      File.rm_rf!(tmp)
      Application.delete_env(:test_flow_phx, :data_dir_override)
    end)

    %{tmp: tmp, config_file: config_file}
  end

  describe "validate_dir/1" do
    test "ok when directory exists and is read-write", %{tmp: tmp} do
      assert :ok = Settings.validate_dir(tmp)
    end

    test "creates and validates when path does not exist yet", %{tmp: tmp} do
      target = Path.join(tmp, "nested/new_dir")
      refute File.exists?(target)

      assert :ok = Settings.validate_dir(target)
      assert File.dir?(target)
    end

    test "errors with :empty_path for empty string" do
      assert {:error, :empty_path} = Settings.validate_dir("")
    end

    test "errors when target is a file, not a directory", %{tmp: tmp} do
      file = Path.join(tmp, "a-file")
      File.write!(file, "x")
      assert {:error, {:not_a_directory, :regular}} = Settings.validate_dir(file)
    end

    test "errors with :not_writable when permissions deny writing", %{tmp: tmp} do
      ro = Path.join(tmp, "readonly")
      File.mkdir_p!(ro)
      File.chmod!(ro, 0o555)

      assert {:error, :not_writable} = Settings.validate_dir(ro)
    after
      # restore so tmp can be cleaned up
      Path.join(System.tmp_dir!(), "tf_settings_*")
      |> Path.wildcard()
      |> Enum.each(&File.chmod(&1, 0o755))
    end
  end

  describe "set_data_dir/1 + get" do
    test "persists to the config file and updates Application env", %{tmp: tmp, config_file: config_file} do
      target = Path.join(tmp, "store")

      assert {:ok, ^target} = Settings.set_data_dir(target)
      assert Application.get_env(:test_flow_phx, :data_dir_override) == target

      assert {:ok, body} = File.read(config_file)
      assert {:ok, %{"data_dir" => ^target}} = Jason.decode(body)

      # With TEST_FLOW_DATA_DIR cleared, the Application override (set by
      # Settings.set_data_dir/1) becomes the effective value.
      env = System.get_env("TEST_FLOW_DATA_DIR")
      System.delete_env("TEST_FLOW_DATA_DIR")

      try do
        assert Settings.get_data_dir() == target
      after
        if env, do: System.put_env("TEST_FLOW_DATA_DIR", env)
      end
    end

    test "validation error is surfaced and nothing is persisted", %{tmp: tmp, config_file: config_file} do
      file = Path.join(tmp, "not-a-dir")
      File.write!(file, "x")

      assert {:error, {:not_a_directory, :regular}} = Settings.set_data_dir(file)
      refute Application.get_env(:test_flow_phx, :data_dir_override)
      refute File.exists?(config_file)
    end

    test "expands ~ in input" do
      home = System.user_home!()

      target = "~/.test_flow_phx_settings_test_#{System.unique_integer([:positive])}"
      expected = Path.join(home, String.trim_leading(target, "~/"))

      assert {:ok, ^expected} = Settings.set_data_dir(target)
      File.rm_rf!(expected)
    end
  end

  describe "read_persisted_data_dir/0" do
    test "returns the saved dir", %{tmp: tmp} do
      target = Path.join(tmp, "saved")
      assert {:ok, _} = Settings.set_data_dir(target)
      assert Settings.read_persisted_data_dir() == {:ok, target}
    end

    test "returns :error when no config has been written yet" do
      assert Settings.read_persisted_data_dir() == :error
    end
  end
end
