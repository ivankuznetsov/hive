require_relative "../test_helper"
require "open3"
require "rbconfig"

class CliHelpTest < Minitest::Test
  HIVE_BIN = File.expand_path("../../bin/hive", __dir__)

  def test_status_help_after_subcommand_options_shows_usage
    Dir.mktmpdir("hive-help-test") do |hive_home|
      out, err, status = Open3.capture3(
        { "HIVE_HOME" => hive_home },
        RbConfig.ruby, "-Ilib", HIVE_BIN, "status", "--project", "demo", "--help"
      )

      assert status.success?, "bin/hive status --project demo --help should exit 0, stderr was: #{err}"
      assert_includes out, "Usage:"
      assert_includes out, "status"
      refute_includes err, "help was called with arguments"
    end
  end
end
