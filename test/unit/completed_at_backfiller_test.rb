require "test_helper"
require "hive/completed_at_backfiller"

class CompletedAtBackfillerTest < Minitest::Test
  include HiveTestHelper

  def test_backfills_once_from_terminal_transition_history
    with_archived_task do |task, state|
      backfiller = Hive::CompletedAtBackfiller.new

      first = backfiller.completed_at_for(task)
      first_head = run!("git", "-C", state, "rev-parse", "HEAD").strip
      second = backfiller.completed_at_for(Hive::Task.new(task.folder))

      assert_equal Time.utc(2026, 7, 19, 8, 0, 0), first
      assert_equal first, second
      assert_equal "2026-07-19T08:00:00Z", Hive::TaskMeta.read(task.folder)[:completed_at]
      assert_equal first_head, run!("git", "-C", state, "rev-parse", "HEAD").strip
    end
  end

  def test_failed_persistence_restores_metadata_and_fails_open
    with_archived_task do |task, _state|
      backfiller = Hive::CompletedAtBackfiller.new
      backfiller.define_singleton_method(:commit) { |_task| raise Hive::GitError, "commit failed" }

      value = nil
      _out, err = capture_io { value = backfiller.completed_at_for(task) }

      assert_nil value
      refute Hive::TaskMeta.read(task.folder).key?(:completed_at)
      assert_includes err, "keeping task visible"
    end
  end

  private

  def with_archived_task
    with_tmp_dir do |project|
      state = File.join(project, ".hive-state")
      folder = File.join(state, "stages", "9-done", "archive-me-260719-abcd")
      FileUtils.mkdir_p(folder)
      Hive::TaskMeta.write(folder, id: 1, slug: File.basename(folder), display_name: nil)
      File.write(File.join(folder, "task.md"), "# Done\n<!-- COMPLETE -->\n")
      run!("git", "-C", state, "init", "-b", "hive/state", "--quiet")
      run!("git", "-C", state, "config", "user.email", "test@example.com")
      run!("git", "-C", state, "config", "user.name", "Test")
      run!("git", "-C", state, "config", "commit.gpgsign", "false")
      run!("git", "-C", state, "add", ".")
      with_env(
        "GIT_AUTHOR_DATE" => "2026-07-19T08:00:00Z",
        "GIT_COMMITTER_DATE" => "2026-07-19T08:00:00Z"
      ) do
        run!(
          "git", "-C", state, "commit", "-m",
          "hive: 8-finalize/#{File.basename(folder)} approve 8-finalize -> 9-done", "--quiet"
        )
      end
      yield Hive::Task.new(folder), state
    end
  ensure
    Hive::Workflows::Project.reset!
  end
end
