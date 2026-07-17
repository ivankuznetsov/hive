require "test_helper"
require "hive/config"
require "hive/task"
require "hive/stages/done"

class StagesDoneTest < Minitest::Test
  include HiveTestHelper

  Cleanup = Struct.new(:result) do
    def call = result
  end

  def test_run_reports_completed_cleanup_and_writes_nothing_directly
    with_tmp_dir do |dir|
      task = task_in(dir, "feat-x-260424-aaaa")
      cleanup = Cleanup.new(
        Hive::Finalization::ArchiveCleanup::Result.new(
          status: :completed, event_id: "cleanup-1", worktree: "/safe/worktree", branch: task.slug
        )
      )

      result = nil
      out, err = capture_io do
        result = Hive::Stages::Done.run!(task, Hive::Config.load(dir), cleanup: cleanup)
      end

      assert_empty out
      assert_empty err
      assert_equal "archived", result[:commit]
      assert_equal :complete, result[:status]
      assert_includes result[:cleanup_instructions].join("\n"), "cleanup receipt: cleanup-1"
      assert_equal :complete, Hive::Markers.current(task.state_file).name
    end
  end

  def test_run_reports_an_existing_receipt_idempotently
    with_tmp_dir do |dir|
      task = task_in(dir, "feat-y-260424-bbbb")
      cleanup = Cleanup.new(
        Hive::Finalization::ArchiveCleanup::Result.new(
          status: :already_completed, event_id: "cleanup-1", worktree: nil, branch: nil
        )
      )

      result = Hive::Stages::Done.run!(task, Hive::Config.load(dir), cleanup: cleanup)

      assert_equal [ "Task #{task.slug} archive cleanup already completed (receipt cleanup-1)." ],
                   result[:cleanup_instructions]
    end
  end

  private

  def task_in(dir, slug)
    folder = File.join(dir, ".hive-state", "stages", "9-done", slug)
    FileUtils.mkdir_p(folder)
    Hive::Task.new(folder)
  end
end
