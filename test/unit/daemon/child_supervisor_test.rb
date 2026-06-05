require "test_helper"
require "open3"
require "rbconfig"
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
        project: "p1", slug: "slug-a", stage: "6-review"
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
        project: "p1", slug: "slug-a", stage: "6-review"
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
        project: "p1", slug: "slug-a", stage: "6-review"
      )
      completed = wait_for_completion(sup, max_attempts: 50)
      assert_equal 1, completed.size
      assert_equal 75, completed.first.exit_code
    end
  end

  def test_spawn_tmpdir_log_fallback_loads_its_own_dependency
    script = <<~RUBY
      require "hive/daemon/child_supervisor"

      sup = Hive::Daemon::ChildSupervisor.new(hive_bin: #{FAKE_HIVE.inspect})
      sup.spawn(
        command_string: "hive run tmpdir-fallback --exit-code 0",
        project: "p1",
        slug: "tmpdir-fallback",
        stage: "1-inbox"
      )

      deadline = Time.now + 5
      completed = []
      until Time.now > deadline || completed.any?
        completed.concat(sup.reap_all)
        sleep 0.05
      end

      abort "child did not complete" if completed.empty?
      abort "exit=\#{completed.first.exit_code}" unless completed.first.exit_code == 0
    RUBY

    _out, err, status = Open3.capture3(RbConfig.ruby, "-Ilib", "-e", script)
    assert status.success?, err
  end

  def test_spawn_two_children_reap_returns_both
    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      sup.spawn(command_string: "hive run a --exit-code 0",
                project: "p1", slug: "a", stage: "6-review")
      sup.spawn(command_string: "hive run b --exit-code 0",
                project: "p2", slug: "b", stage: "6-review")
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
      project: "p1", slug: "a", stage: "6-review"
    )
    assert pid < 0, "dry-run returns a synthetic non-positive PID"
    assert_equal 1, sup.in_flight_count
    assert_equal [ pid ], sup.in_flight_pids

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
      project: "p1", slug: "a", stage: "6-review", dry_run: true
    )
    assert pid < 0
  end

  # ── refuses non-hive commands ─────────────────────────────────────────

  def test_spawn_refuses_non_hive_command_string
    sup = make
    err = assert_raises(ArgumentError) do
      sup.spawn(command_string: "rm -rf / # gotcha",
                project: "p1", slug: "x", stage: "6-review")
    end
    assert_match(/refuses non-hive command/, err.message)
  end

  # ── terminate_all sends SIGTERM, escalates to SIGKILL ─────────────────

  # PR-40 follow-up review C1: parse_envelope used to call
  # File.foreach.to_a.last(20), materializing the whole file. A child
  # writing tens of MB of stdout would OOM the daemon. The fix is a
  # bounded tail-read; verify it both extracts the envelope correctly
  # for a normal file AND tolerates a giant prefix.
  def test_parse_envelope_extracts_tail_envelope_from_large_log
    skip "skipping large-log test under CI containers" if ENV["CI"] == "true"

    with_tmp_dir do |dir|
      log_path = File.join(dir, "huge.log")
      # Write 8 MB of prose, then the JSON envelope as the last line.
      File.open(log_path, "wb") do |f|
        line = "noise " * 100 + "\n" # ~601 bytes per line
        12_000.times { f.write(line) } # ~7.2 MB
        f.write(%({"ok":true,"slug":"big","schema":"hive-run"}\n))
      end
      assert File.size(log_path) > 5_000_000, "fixture must exceed the bounded read window"

      sup = make
      envelope = sup.send(:parse_envelope, log_path)
      assert_equal({ "ok" => true, "slug" => "big", "schema" => "hive-run" }, envelope)
    end
  end

  def test_parse_envelope_returns_nil_on_missing_log
    sup = make
    assert_nil sup.send(:parse_envelope, "/no/such/path.log")
  end

  def test_parse_envelope_returns_nil_when_no_json_in_tail
    with_tmp_dir do |dir|
      log_path = File.join(dir, "prose-only.log")
      File.write(log_path, "no json here\nstill no json\n")
      sup = make
      assert_nil sup.send(:parse_envelope, log_path)
    end
  end

  def test_parse_envelope_skips_malformed_json_lines
    with_tmp_dir do |dir|
      log_path = File.join(dir, "malformed.log")
      File.write(log_path, "[hive-daemon] header\n{not-json}\n")
      sup = make

      assert_nil sup.send(:parse_envelope, log_path)
    end
  end

  def test_read_tail_returns_nil_on_io_errors
    sup = make

    with_replaced_singleton_method(File, :open, ->(*_args, **_kwargs) { raise Errno::EACCES, "blocked" }) do
      assert_nil sup.send(:read_tail, "blocked.log", 64)
    end
  end

  def test_terminate_all_escalates_survivors_to_kill
    sup = make
    sup.instance_variable_set(:@running, {
      123 => { project: "p1", slug: "a", stage: "6-review", command: "hive run a" },
      456 => { project: "p1", slug: "b", stage: "6-review", command: "hive run b" }
    })
    kills = []
    reap_calls = 0

    sup.define_singleton_method(:collect_pgids) { [ 99 ] }
    sup.define_singleton_method(:safe_kill) { |signal, target| kills << [ signal, target ] }
    sup.define_singleton_method(:reap_all) do
      reap_calls += 1
      []
    end

    with_replaced_singleton_method(Process, :getpgid, lambda { |pid|
      raise Errno::ESRCH if pid == 456

      1000 + pid
    }) do
      sup.terminate_all(grace_sec: 0)
    end

    assert_equal [ [ :TERM, -99 ], [ :KILL, -1123 ], [ :KILL, -456 ] ], kills
    assert_equal 1, reap_calls
  end

  def test_terminate_all_wait_loop_reaps_before_deadline
    sup = make
    sup.instance_variable_set(:@running, {
      123 => { project: "p1", slug: "a", stage: "6-review", command: "hive run a" }
    })
    reap_calls = 0
    kills = []

    sup.define_singleton_method(:collect_pgids) { [] }
    sup.define_singleton_method(:safe_kill) { |signal, target| kills << [ signal, target ] }
    sup.define_singleton_method(:reap_all) do
      reap_calls += 1
      if reap_calls == 1
        [ Object.new ]
      else
        instance_variable_get(:@running).clear
        []
      end
    end

    sup.terminate_all(grace_sec: 1)

    assert_equal 2, reap_calls
    assert_empty kills
    assert_equal 0, sup.in_flight_count
  end

  def test_collect_pgids_deduplicates_and_ignores_exited_children
    sup = make
    sup.instance_variable_set(:@running, {
      111 => { project: "p1", slug: "a", stage: "6-review", command: "hive run a" },
      222 => { project: "p1", slug: "b", stage: "6-review", command: "hive run b" },
      333 => { project: "p1", slug: "gone", stage: "6-review", command: "hive run gone" }
    })

    with_replaced_singleton_method(Process, :getpgid, lambda { |pid|
      raise Errno::ESRCH if pid == 333

      42
    }) do
      assert_equal [ 42 ], sup.send(:collect_pgids)
    end
  end

  def test_safe_kill_sends_signal_to_target
    sup = make
    calls = []

    with_replaced_singleton_method(Process, :kill, lambda { |signal, target|
      calls << [ signal, target ]
      1
    }) do
      assert_equal 1, sup.send(:safe_kill, :TERM, -123)
    end

    assert_equal [ [ :TERM, -123 ] ], calls
  end

  def test_terminate_all_signals_running_children
    skip "skipping signal test under CI containers" if ENV["CI"] == "true"

    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      # Child sleeps for 30s; we'll TERM it.
      sup.spawn(command_string: "hive run a --exit-code 0 --sleep 30",
                project: "p1", slug: "a", stage: "6-review")
      assert_equal 1, sup.in_flight_count

      sup.terminate_all(grace_sec: 2)
      assert_equal 0, sup.in_flight_count, "TERM (with grace) must reap all running children"
    end
  end

  # ── R-02: per-verb wall-clock timeout ─────────────────────────────────

  def test_timeout_for_verb_resolves_default_and_override
    sup = Hive::Daemon::ChildSupervisor.new(
      hive_bin: FAKE_HIVE,
      default_timeout_sec: 100,
      verb_timeouts: { "review" => 600 }
    )
    assert_equal 600, sup.timeout_for_verb("review"), "per-verb override wins"
    assert_equal 100, sup.timeout_for_verb("develop"), "falls back to default"
    assert_equal 100, sup.timeout_for_verb(""), "empty verb falls back to default"
  end

  def test_enforce_timeouts_terms_then_kills_over_deadline_child
    sup = Hive::Daemon::ChildSupervisor.new(
      hive_bin: FAKE_HIVE, default_timeout_sec: 60, kill_grace_sec: 30
    )
    started = Time.now
    sup.instance_variable_set(:@running, {
      123 => { project: "p1", slug: "a", stage: "6-review", command: "hive run a",
               started_at: started, timeout_sec: 60, dry_run: false }
    })
    kills = []
    sup.define_singleton_method(:pgid_for) { |pid| 900 + pid }
    sup.define_singleton_method(:safe_kill) { |signal, target| kills << [ signal, target ] }

    # Not yet over the deadline.
    assert_empty sup.enforce_timeouts(now: started + 59)
    assert_empty kills

    # Over the deadline → SIGTERM once.
    term = sup.enforce_timeouts(now: started + 61)
    assert_equal 1, term.size
    assert_equal :term, term.first.action
    assert_equal 61, term.first.elapsed_sec
    assert_equal 60, term.first.timeout_sec
    assert_equal [ [ :TERM, -1023 ] ], kills

    # Still alive, but within the kill grace → no second signal.
    assert_empty sup.enforce_timeouts(now: started + 80)
    assert_equal [ [ :TERM, -1023 ] ], kills

    # Grace elapsed → SIGKILL once, then never again.
    kill = sup.enforce_timeouts(now: started + 95)
    assert_equal 1, kill.size
    assert_equal :kill, kill.first.action
    assert_equal [ [ :TERM, -1023 ], [ :KILL, -1023 ] ], kills
    assert_empty sup.enforce_timeouts(now: started + 200), "kill is sent at most once"
  end

  def test_enforce_timeouts_disabled_when_timeout_zero
    sup = Hive::Daemon::ChildSupervisor.new(hive_bin: FAKE_HIVE, default_timeout_sec: 0)
    sup.instance_variable_set(:@running, {
      123 => { project: "p1", slug: "a", stage: "6-review", command: "hive run a",
               started_at: Time.now - 100_000, timeout_sec: 0, dry_run: false }
    })
    sup.define_singleton_method(:safe_kill) { |*| flunk "0 timeout must never signal a child" }
    assert_empty sup.enforce_timeouts(now: Time.now)
  end

  def test_enforce_timeouts_skips_dry_run_children
    sup = Hive::Daemon::ChildSupervisor.new(hive_bin: FAKE_HIVE, default_timeout_sec: 1)
    sup.instance_variable_set(:@running, {
      -1 => { project: "p1", slug: "a", stage: "6-review", command: "hive run a",
              started_at: Time.now - 100, timeout_sec: 1, dry_run: true }
    })
    sup.define_singleton_method(:safe_kill) { |*| flunk "dry-run children must never be signalled" }
    assert_empty sup.enforce_timeouts(now: Time.now)
  end

  def test_update_timeouts_only_affects_future_spawns
    sup = Hive::Daemon::ChildSupervisor.new(hive_bin: FAKE_HIVE, default_timeout_sec: 60)
    sup.update_timeouts(default_timeout_sec: 5, verb_timeouts: { "develop" => 9 }, kill_grace_sec: 1)
    assert_equal 9, sup.timeout_for_verb("develop")
    assert_equal 5, sup.timeout_for_verb("review")
  end

  def test_pgid_for_returns_nil_when_group_gone
    sup = make
    # A pid with no process group → Process.getpgid raises ESRCH → the
    # helper returns nil so the caller's `if pgid` guard skips the kill,
    # rather than signaling `-pid` (which could hit a recycled process
    # group on a long-running host) (#249).
    assert_nil sup.send(:pgid_for, 2**30),
               "pgid_for must return nil on ESRCH so the kill is skipped, not retargeted at -pid"
  end

  def test_enforce_timeouts_kills_real_sleeping_child
    skip "skipping signal test under CI containers" if ENV["CI"] == "true"

    with_tmp_dir do |dir|
      sup = Hive::Daemon::ChildSupervisor.new(
        hive_bin: FAKE_HIVE,
        log_dir_for_task: ->(project, slug) { File.join(dir, project, slug, "child.log") },
        default_timeout_sec: 1, kill_grace_sec: 0
      )
      sup.spawn(command_string: "hive run a --exit-code 0 --sleep 30",
                project: "p1", slug: "a", stage: "6-review")
      assert_equal 1, sup.in_flight_count

      # Past the 1s deadline with a 0s kill-grace: TERM then KILL.
      actions = sup.enforce_timeouts(now: Time.now + 5)
      sup.enforce_timeouts(now: Time.now + 6)
      assert(actions.any? { |a| a.action == :term })

      completed = wait_for_completion(sup, max_attempts: 100)
      assert_equal 1, completed.size, "the killed child must surface as a ChildExit on reap"
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
