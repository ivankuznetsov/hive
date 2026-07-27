require "test_helper"
require "hive/completion_time"

class CompletionTimeTest < Minitest::Test
  include HiveTestHelper

  TaskDouble = Struct.new(
    :state_file, :folder, :workflow, :action_workflow, :hive_state_path, :slug,
    keyword_init: true
  )

  def test_parse_normalizes_offsets_and_rejects_malformed_values
    assert_equal Time.utc(2026, 7, 22, 10, 30, 0),
                 Hive::CompletionTime.parse("2026-07-22T12:30:00+02:00")
    assert_nil Hive::CompletionTime.parse("yesterday")
  end

  def test_parse_warns_and_fails_open_for_timestamp_shaped_invalid_values
    value = :not_set
    _out, err = capture_io do
      value = Hive::CompletionTime.parse(
        "2026-99-99T00:00:00Z", warn_context: "/task/meta.yml"
      )
    end

    assert_nil value
    assert_includes err, "invalid completed_at for /task/meta.yml"
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

  def test_history_uses_membership_workflow_after_policy_repin
    membership_stage = Hive::Workflow::Stage.new(
      name: "done", index: 1, state_file: "done.md", kind: :inert
    )
    policy_stage = Hive::Workflow::Stage.new(
      name: "published", index: 1, state_file: "published.md", kind: :inert
    )
    task = TaskDouble.new(
      state_file: "/tmp/done.md", folder: "/tmp/task",
      workflow: Hive::Workflow.new(id: :policy, stages: [ policy_stage ]),
      action_workflow: Hive::Workflow.new(id: :membership, stages: [ membership_stage ]),
      hive_state_path: "/tmp/state", slug: "repinned"
    )
    history = Object.new
    history.define_singleton_method(:commits) do |**|
      [
        {
          sha: "arrival", committed_at: "2026-07-20T10:00:00Z",
          subject: "hive: 0-work/repinned approve 0-work -> 1-done"
        }
      ]
    end

    assert_equal Time.utc(2026, 7, 20, 10, 0, 0),
                 Hive::CompletionTime.from_history(task, history: history)
  end

  def test_history_command_runner_kills_work_at_deadline
    runner = Hive::CompletionTime::CommandRunner.new
    clock = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
    started = clock.call

    assert_raises(Hive::CompletionTime::DeadlineExceeded) do
      runner.capture(
        [ RbConfig.ruby, "-e", "sleep 5" ],
        deadline: started + 0.05, monotonic_clock: clock
      )
    end

    assert_operator clock.call - started, :<, 0.5
  end

  def test_history_command_runner_times_out_blocked_readers_and_closes_streams
    runner = Hive::CompletionTime::CommandRunner.new
    runner.define_singleton_method(:terminate) { |_waiter| nil }
    stdin = StringIO.new
    streams = 2.times.map do
      queue = Queue.new
      stream = Object.new
      stream.define_singleton_method(:read) { queue.pop; "" }
      stream.define_singleton_method(:closed?) { false }
      stream.define_singleton_method(:close) do
        queue << :closed
        raise IOError, "already closed"
      end
      stream
    end
    waiter = Object.new
    waiter.define_singleton_method(:join) { |_timeout| true }
    clock_values = [ 0.0, 2.0 ]
    clock = -> { clock_values.shift || 2.0 }

    with_replaced_singleton_method(
      Open3, :popen3, ->(*) { [ stdin, *streams, waiter ] }
    ) do
      assert_raises(Hive::CompletionTime::DeadlineExceeded) do
        runner.capture([ "fake" ], deadline: 1.0, monotonic_clock: clock)
      end
    end
  end

  def test_command_runner_terminate_tolerates_an_already_dead_process_group
    waiter = Object.new
    waiter.define_singleton_method(:pid) { 12_345 }
    waiter.define_singleton_method(:join) { |_timeout| true }

    with_replaced_singleton_method(
      Process, :kill, ->(*) { raise Errno::ESRCH }
    ) do
      Hive::CompletionTime::CommandRunner.new.send(:terminate, waiter)
    end

    assert true
  end

  def test_history_file_at_returns_content_only_for_a_successful_git_show
    success = Object.new
    success.define_singleton_method(:success?) { true }
    failure = Object.new
    failure.define_singleton_method(:success?) { false }
    calls = 0
    replacement = lambda do |*|
      calls += 1
      calls == 1 ? [ "contents", "", success ] : [ "", "missing", failure ]
    end
    history = Hive::CompletionTime::History.new

    with_replaced_singleton_method(Open3, :capture3, replacement) do
      assert_equal "contents", history.file_at(
        hive_state_path: "/state", sha: "abc", relative_path: "meta.yml"
      )
      assert_nil history.file_at(
        hive_state_path: "/state", sha: "def", relative_path: "meta.yml"
      )
    end
  end

  def test_discovery_rejects_an_expired_shared_deadline_before_history_work
    assert_raises(Hive::CompletionTime::DeadlineExceeded) do
      Hive::CompletionTime.discover(
        Object.new, deadline: 1.0, monotonic_clock: -> { 1.0 }
      )
    end
  end
end
