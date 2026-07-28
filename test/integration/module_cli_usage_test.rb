require "open3"
require "test_helper"

class ModuleCliUsageTest < Minitest::Test
  def test_pre_thor_and_in_command_usage_errors_emit_one_module_document
    [
      [ %w[module --json], "hive-module-lifecycle" ],
      [ %w[module list extra extra --json], "hive-module-list" ],
      [ %w[module migration status extra --json], "hive-module-migration" ],
      [ %w[module migration report extra --json], "hive-module-migration-report" ],
      [ %w[module unknown --json], "hive-module-lifecycle" ]
    ].each do |argv, schema|
      out, _err, status = Open3.capture3(File.expand_path("../../bin/hive", __dir__), *argv)
      documents = out.lines.reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
      assert_equal 1, documents.length, argv.join(" ")
      assert_equal schema, documents.first.fetch("schema")
      refute documents.first.fetch("ok")
      assert_equal Hive::ExitCodes::USAGE, status.exitstatus
    end
  end
end
