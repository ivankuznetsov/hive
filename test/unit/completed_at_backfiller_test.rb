require "test_helper"
require "hive/completed_at_backfiller"

class CompletedAtBackfillerTest < Minitest::Test
  include HiveTestHelper
  BackfillTask = Data.define(:folder, :hive_state_path)

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

  def test_task_deleted_while_waiting_for_commit_lock_is_not_recreated
    with_archived_task do |task, _state|
      observed_timeout = nil
      replacement = lambda do |_path, timeout:, &block|
        observed_timeout = timeout
        FileUtils.rm_rf(task.folder)
        block.call
      end

      with_replaced_singleton_method(Hive::Lock, :with_commit_lock, replacement) do
        assert_nil Hive::CompletedAtBackfiller.new.completed_at_for(task)
      end

      assert_operator observed_timeout, :<=, Hive::CompletedAtBackfiller::REFRESH_DEADLINE_SECONDS
      refute File.exist?(task.folder)
    end
  end

  def test_call_stops_attempting_tasks_at_the_refresh_deadline
    now = 0.0
    tasks = 5.times.map { |index| BackfillTask.new("/task-#{index}", "/state") }
    backfiller = Hive::CompletedAtBackfiller.new(
      batch_size: 5, deadline_seconds: 1.0, monotonic_clock: -> { now }
    )
    attempted = []
    backfiller.define_singleton_method(:completed_at_for) do |task, deadline:|
      attempted << [ task.folder, deadline ]
      now += 0.6
      nil
    end

    backfiller.call(tasks)

    assert_equal %w[/task-0 /task-1], attempted.map(&:first)
    assert attempted.all? { |_folder, deadline| deadline == 1.0 }
  end

  def test_rotating_batches_advance_past_persistent_failures
    tasks = 3.times.map { |index| BackfillTask.new("/task-#{index}", "/state") }
    Hive::CompletedAtBackfiller.reset_progress!

    first = Hive::CompletedAtBackfiller.rotating_batch(tasks, 2)
    second = Hive::CompletedAtBackfiller.rotating_batch(tasks, 2)

    assert_equal %w[/task-0 /task-1], first.map(&:folder)
    assert_equal %w[/task-2 /task-0], second.map(&:folder)
  ensure
    Hive::CompletedAtBackfiller.reset_progress!
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
