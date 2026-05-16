# Isolate `data/` per-test-run from the working tree so SendRequest's body
# persistence (and any other Paths.data_dir/0 consumer) writes under /tmp.
# Individual tests that need a hermetic dir still create their own; this
# is just a safety net for incidental writes.
unless System.get_env("TEST_FLOW_DATA_DIR") do
  tmp = Path.join(System.tmp_dir!(), "test_flow_phx_test_data_#{System.system_time(:second)}")
  File.mkdir_p!(tmp)
  System.put_env("TEST_FLOW_DATA_DIR", tmp)
end

ExUnit.start()
