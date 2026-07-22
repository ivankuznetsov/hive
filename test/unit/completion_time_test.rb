require "test_helper"
require "hive/completion_time"

class CompletionTimeTest < Minitest::Test
  include HiveTestHelper

  TaskDouble = Struct.new(
    :state_file, :folder, :workflow, :hive_state_path, :slug,
    keyword_init: true
  )

  def test_parse_normalizes_offsets_and_rejects_malformed_values
    assert_equal Time.utc(2026, 7, 22, 10, 30, 0),
                 Hive::CompletionTime.parse("2026-07-22T12:30:00+02:00")
    assert_nil Hive::CompletionTime.parse("yesterday")
  end

  def test_discover_falls_back_from_state_file_mtime_to_folder_mtime
    with_tmp_dir do |folder|
      state_file = File.join(folder, "done.md")
      File.write(state_file, "done")
      task_time = Time.utc(2026, 7, 20, 8, 0, 0)
      folder_time = Time.utc(2026, 7, 19, 8, 0, 0)
      File.utime(task_time, task_time, state_file)
      File.utime(folder_time, folder_time, folder)
      task = TaskDouble.new(state_file: state_file, folder: folder)

      assert_equal task_time, Hive::CompletionTime.discover_from_mtimes(task)

      File.delete(state_file)
      File.utime(folder_time, folder_time, folder)
      assert_equal folder_time, Hive::CompletionTime.discover_from_mtimes(task)
    end
  end

  def test_history_uses_first_credible_active_terminal_completion
    stage = Hive::Workflow::Stage.new(
      name: "publish", index: 1, state_file: "report.md", kind: :agent,
      deliverable: "report.md"
    )
    task = TaskDouble.new(
      state_file: "/tmp/report.md", folder: "/tmp/task",
      workflow: Hive::Workflow.new(id: :publish, stages: [ stage ]),
      hive_state_path: "/tmp/state", slug: "publish-me"
    )
    entries = [
      { sha: "later", committed_at: "2026-07-22T10:00:00Z", subject: "hive: 1-publish/publish-me complete" },
      { sha: "earlier", committed_at: "2026-07-20T10:00:00Z", subject: "hive: 1-publish/publish-me complete" },
      { sha: "error", committed_at: "2026-07-19T10:00:00Z", subject: "hive: 1-publish/publish-me error" }
    ]
    history = Object.new
    history.define_singleton_method(:commits) { |**| entries }
    history.define_singleton_method(:file_at) do |sha:, **|
      sha == "error" ? "<!-- ERROR -->" : "# Report\n<!-- COMPLETE -->\n"
    end

    assert_equal Time.utc(2026, 7, 20, 10, 0, 0),
                 Hive::CompletionTime.from_history(task, history: history)
  end
end
