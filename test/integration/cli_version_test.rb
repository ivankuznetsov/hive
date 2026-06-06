require "test_helper"
require "json"
require "open3"
require "rbconfig"

class CliVersionTest < Minitest::Test
  include HiveTestHelper

  def test_bin_hive_version_outputs_version
    out = run!(RbConfig.ruby, "-Ilib", "bin/hive", "--version")

    assert_equal "#{Hive::VERSION}\n", out
  end

  def test_bin_hive_leading_json_status_keeps_status_command_semantics
    with_tmp_global_config do
      out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "bin/hive", "--json", "status")
      assert status.success?, "bin/hive --json status should exit 0, stderr was: #{err}"

      payload = JSON.parse(out)
      assert_equal "hive-status", payload["schema"]
      assert_equal true, payload["ok"]
    end
  end
end
