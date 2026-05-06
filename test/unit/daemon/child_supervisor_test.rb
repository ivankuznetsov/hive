require "test_helper"
require "tmpdir"
require "hive/daemon/child_supervisor"

# Pin the supervisor's spawn / reap / terminate semantics. Uses
# test/fixtures/fake-hive-run.rb as the binary so exit-code branches
# are deterministic and don't need a real `claude` install.
class HiveDaemonChildSupervisorTest < Minitest::Test
  include HiveTestHelper

  FAKE_HIVE = File.expand_path("../../fixtures/fake-hive-run.rb", __dir__)

  def make(dry_run: false, log_dir: nil)
    log_lambda = log_dir ? lambda { |project, slug| File.join(log_dir, project, slug, "child.log") } : nil
    Hive::Daemon::ChildSupervisor.new(
      hive_bin: FAKE_HIVE,
      dry_run: dry_run,
      log_dir_for_task: log_lambda
    )
  end

  # ── spawn + reap_all (real subprocess) ────────────────────────────────

  def test_spawn_and_reap_returns_completed_child_with_envelope
    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      # Single-quote the JSON arg so Shellwords.split preserves the
      # double-quotes in the JSON literal.
      pid = sup.spawn(
        command_string: %q(hive run slug-a --json --exit-code 0 --stdout-text '{"ok":true,"slug":"a"}'),
        project: "p1", slug: "slug-a", stage: "5-review"
      )
      assert pid > 0, "real spawn returns a positive PID"

      # Wait for it to exit (it's a tiny script; should finish in ms).
      completed = wait_for_completion(sup, max_attempts: 50)
      assert_equal 1, completed.size
      entry = completed.first
      assert_equal pid, entry.pid
      assert_equal 0, entry.exit_code
      assert_equal "p1", entry.project
      assert_equal "slug-a", entry.slug
      assert_equal({ "ok" => true, "slug" => "a" }, entry.json_envelope)
    end
  end

  def test_reap_all_returns_empty_when_nothing_running
    sup = make
    assert_equal [], sup.reap_all
  end

  def test_spawn_with_invalid_json_stdout_returns_nil_envelope
    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      sup.spawn(
        command_string: %(hive run slug-a --exit-code 0 --stdout-text this-is-not-json),
        project: "p1", slug: "slug-a", stage: "5-review"
      )
      completed = wait_for_completion(sup, max_attempts: 50)
      assert_equal 1, completed.size
      assert_nil completed.first.json_envelope,
                 "supervisor must tolerate non-JSON stdout without crashing"
    end
  end

  def test_spawn_propagates_nonzero_exit_codes
    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      sup.spawn(
        command_string: "hive run slug-a --exit-code 75",
        project: "p1", slug: "slug-a", stage: "5-review"
      )
      completed = wait_for_completion(sup, max_attempts: 50)
      assert_equal 1, completed.size
      assert_equal 75, completed.first.exit_code
    end
  end

  def test_spawn_two_children_reap_returns_both
    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      sup.spawn(command_string: "hive run a --exit-code 0",
                project: "p1", slug: "a", stage: "5-review")
      sup.spawn(command_string: "hive run b --exit-code 0",
                project: "p2", slug: "b", stage: "5-review")
      completed = wait_for_completion(sup, expected: 2, max_attempts: 100)
      assert_equal 2, completed.size
      slugs = completed.map(&:slug).sort
      assert_equal %w[a b], slugs
    end
  end

  # ── dry-run ───────────────────────────────────────────────────────────

  def test_dry_run_does_not_spawn_real_process
    sup = make(dry_run: true)
    pid = sup.spawn(
      command_string: "hive run a --exit-code 0",
      project: "p1", slug: "a", stage: "5-review"
    )
    assert pid < 0, "dry-run returns a synthetic non-positive PID"
    assert_equal 1, sup.in_flight_count

    # No real child to reap; reap_dry_run synthesises an exit.
    completed = sup.reap_dry_run
    assert_equal 1, completed.size
    assert_equal 0, completed.first.exit_code
    assert_equal "a", completed.first.slug
  end

  def test_dry_run_param_overrides_supervisor_default
    # Supervisor was created with dry_run: false, but a single spawn
    # opts in via dry_run: true.
    sup = make(dry_run: false)
    pid = sup.spawn(
      command_string: "hive run a --exit-code 0",
      project: "p1", slug: "a", stage: "5-review", dry_run: true
    )
    assert pid < 0
  end

  # ── refuses non-hive commands ─────────────────────────────────────────

  def test_spawn_refuses_non_hive_command_string
    sup = make
    err = assert_raises(ArgumentError) do
      sup.spawn(command_string: "rm -rf / # gotcha",
                project: "p1", slug: "x", stage: "5-review")
    end
    assert_match(/refuses non-hive command/, err.message)
  end

  # ── terminate_all sends SIGTERM, escalates to SIGKILL ─────────────────

  def test_terminate_all_signals_running_children
    skip "skipping signal test under CI containers" if ENV["CI"] == "true"

    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      # Child sleeps for 30s; we'll TERM it.
      sup.spawn(command_string: "hive run a --exit-code 0 --sleep 30",
                project: "p1", slug: "a", stage: "5-review")
      assert_equal 1, sup.in_flight_count

      sup.terminate_all(grace_sec: 2)
      assert_equal 0, sup.in_flight_count, "TERM (with grace) must reap all running children"
    end
  end

  private

  def wait_for_completion(sup, expected: 1, max_attempts: 50)
    completed = []
    max_attempts.times do
      completed.concat(sup.reap_all)
      break if completed.size >= expected

      sleep 0.05
    end
    completed
  end
end
