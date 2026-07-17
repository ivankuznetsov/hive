require "test_helper"
require "hive/daemon/auto_retry_safety"

class HiveDaemonAutoRetrySafetyTest < Minitest::Test
  include HiveTestHelper
  Row = Struct.new(:folder, :state_file, keyword_init: true)

  def test_dirty_or_partial_work_is_preservation_context_not_eligibility
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "partial work")
      context = Hive::Daemon::AutoRetrySafety.preservation_context(
        Row.new(folder: dir, state_file: state_file)
      )

      assert_equal true, context.fetch("folder_present")
      assert_equal true, context.fetch("state_file_present")
      refute_respond_to Hive::Daemon::AutoRetrySafety, :safe_to_retry?
    end
  end
end
