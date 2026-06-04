defmodule TestFlowPhx.Infrastructure.Storage.PathsTest do
  use ExUnit.Case, async: false

  alias TestFlowPhx.Infrastructure.Storage.Paths

  describe "data_dir/0" do
    test "honors TEST_FLOW_DATA_DIR when set" do
      System.put_env("TEST_FLOW_DATA_DIR", "/tmp/test_flow_test_dir")

      try do
        assert Paths.data_dir() == "/tmp/test_flow_test_dir"
      after
        System.delete_env("TEST_FLOW_DATA_DIR")
      end
    end

    test "falls back to <cwd>/data when env var is absent" do
      # Restaurar la env var al salir: test_helper.exs la fija como red de
      # seguridad global (ningún test escribe en ./data real). Borrarla sin
      # restaurar dejaría a los tests posteriores escribiendo en ./data.
      prev = System.get_env("TEST_FLOW_DATA_DIR")
      System.delete_env("TEST_FLOW_DATA_DIR")

      try do
        assert Paths.data_dir() == Path.join(File.cwd!(), "data")
      after
        if prev, do: System.put_env("TEST_FLOW_DATA_DIR", prev)
      end
    end
  end

  describe "state_file/0" do
    test "is data_dir + state.json" do
      System.put_env("TEST_FLOW_DATA_DIR", "/tmp/test_flow_state")

      try do
        assert Paths.state_file() == "/tmp/test_flow_state/state.json"
      after
        System.delete_env("TEST_FLOW_DATA_DIR")
      end
    end
  end

  describe "result_dir/2" do
    test "composes <data_dir>/<protocol>/<YYYY-MM-DD>" do
      System.put_env("TEST_FLOW_DATA_DIR", "/tmp/tf")

      try do
        assert Paths.result_dir(:rest, ~D[2026-05-15]) == "/tmp/tf/rest/2026-05-15"
        assert Paths.result_dir(:graphql, ~D[2030-01-02]) == "/tmp/tf/graphql/2030-01-02"
      after
        System.delete_env("TEST_FLOW_DATA_DIR")
      end
    end
  end

  describe "result_file/4" do
    test "appends epoch_ms and extension" do
      System.put_env("TEST_FLOW_DATA_DIR", "/tmp/tf")

      try do
        path = Paths.result_file(:rest, ~D[2026-05-15], 1_778_871_492_426, "json")
        assert path == "/tmp/tf/rest/2026-05-15/1778871492426.json"
      after
        System.delete_env("TEST_FLOW_DATA_DIR")
      end
    end
  end

  describe "result_file_now/2" do
    test "uses utc_today and current epoch ms" do
      System.put_env("TEST_FLOW_DATA_DIR", "/tmp/tf")

      try do
        path = Paths.result_file_now(:rest, "application/json")
        today = Date.utc_today() |> Date.to_iso8601()

        assert String.starts_with?(path, "/tmp/tf/rest/#{today}/")
        assert String.ends_with?(path, ".json")
      after
        System.delete_env("TEST_FLOW_DATA_DIR")
      end
    end
  end

  describe "extension_for/1" do
    test "maps well-known content types" do
      assert Paths.extension_for("application/json") == "json"
      assert Paths.extension_for("application/json; charset=utf-8") == "json"
      assert Paths.extension_for("text/plain; charset=utf-8") == "txt"
      assert Paths.extension_for("text/html") == "html"
      assert Paths.extension_for("application/xml") == "xml"
      assert Paths.extension_for("image/png") == "png"
      assert Paths.extension_for("application/pdf") == "pdf"
    end

    test "honors +json and +xml suffixes" do
      assert Paths.extension_for("application/vnd.foo.bar+json") == "json"
      assert Paths.extension_for("application/hal+json") == "json"
      assert Paths.extension_for("application/atom+xml") == "xml"
    end

    test "falls back to bin for unknown or missing types" do
      assert Paths.extension_for(nil) == "bin"
      assert Paths.extension_for("application/octet-stream") == "bin"
      assert Paths.extension_for("totally/unknown") == "bin"
    end

    test "derives a sane extension for application/* subtypes" do
      assert Paths.extension_for("application/javascript") == "js"
      assert Paths.extension_for("application/x-www-form-urlencoded") == "txt"
    end
  end
end
