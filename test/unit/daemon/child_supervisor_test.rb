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

  def test_spawn_with_log_state_replaces_log_outside_project_git_state
    with_tmp_dir do |dir|
      state_home = File.join(dir, "state-home")
      with_tmp_git_repo do |project_state|
        sup = make
        sup.spawn(
          command_string: "hive run slug-a --exit-code 0 --stdout-text first-run",
          project: "p1", slug: "slug-a", stage: "6-review",
          log_state_path: state_home
        )

        completed = wait_for_completion(sup, max_attempts: 50)
        assert_equal 1, completed.size
        assert_equal 0, completed.first.exit_code

        log_path = File.join(state_home, "logs", "daemon-children", "p1", "slug-a", "daemon-run.log")
        assert File.file?(log_path)
        assert_includes File.read(log_path), "first-run"

        sup.spawn(
          command_string: "hive run slug-a --exit-code 0 --stdout-text second-run",
          project: "p1", slug: "slug-a", stage: "6-review",
          log_state_path: state_home
        )

        completed = wait_for_completion(sup, max_attempts: 50)
        assert_equal 1, completed.size
        assert_equal 0, completed.first.exit_code

        assert_equal [ log_path ], Dir.glob(File.join(File.dirname(log_path), "*.log"))
        assert_includes File.read(log_path), "second-run"
        refute_includes File.read(log_path), "first-run"

        status = run!("git", "-C", project_state, "status", "--porcelain")
        assert_empty status
      end
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

  def test_parse_result_file_accepts_architecture_envelope_larger_than_log_tail
    with_tmp_dir do |dir|
      path = File.join(dir, "result.json")
      payload = { "schema" => "hive-refactor-patrol", "evidence" => "x" * (128 * 1024) }
      File.write(path, JSON.generate(payload))

      parsed = make.send(:parse_result_file, path)

      assert_equal payload, parsed
      assert File.exist?(path), "parsing alone must not unlink before child completion consumes it"
    end
  end

  def test_parse_result_file_does_not_reject_a_valid_large_monorepo_envelope
    with_tmp_dir do |dir|
      path = File.join(dir, "result.json")
      payload = {
        "schema" => "hive-refactor-patrol",
        "feature_results" => [ { "evidence" => "x" * (9 * 1024 * 1024) } ]
      }
      File.binwrite(path, JSON.generate(payload))

      assert_equal payload, make.send(:parse_result_file, path)
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
      123 => {
        project: "p1", slug: "a", stage: "6-review", command: "hive run a",
        dry_run: false
      }
    })
    kills = []
    exit_entry = Hive::Daemon::ChildSupervisor::ChildExit.new(
      pid: 123, exit_code: nil, project: "p1", slug: "a", stage: "6-review",
      command: "hive run a", started_at: Time.now, finished_at: Time.now
    )

    sup.define_singleton_method(:capture_shutdown_targets) do
      { 123 => { pgid: 99, tree: nil } }
    end
    sup.define_singleton_method(:process_group_alive?) { |_pgid| true }
    sup.define_singleton_method(:safe_kill) { |signal, target| kills << [ signal, target ] }
    sup.define_singleton_method(:reap_all) do
      next [] if instance_variable_get(:@running).empty?

      instance_variable_get(:@running).clear
      [ exit_entry ]
    end

    completed = sup.terminate_all(grace_sec: 0)

    assert_equal [ [ :TERM, -99 ], [ :KILL, -99 ] ], kills
    assert_empty completed,
                 "an unverifiable process tree must keep its scheduler claim fenced"
  end

  def test_terminate_all_wait_loop_reaps_before_deadline
    sup = make
    sup.instance_variable_set(:@running, {
      123 => {
        project: "p1", slug: "a", stage: "6-review", command: "hive run a",
        dry_run: false
      }
    })
    reap_calls = 0
    tree = [ { pid: 123, ppid: 1, pgid: 99, start_time: "start", depth: 0 } ]
    exit_entry = Hive::Daemon::ChildSupervisor::ChildExit.new(
      pid: 123, exit_code: nil, project: "p1", slug: "a", stage: "6-review",
      command: "hive run a", started_at: Time.now, finished_at: Time.now
    )

    sup.define_singleton_method(:capture_shutdown_targets) do
      { 123 => { pgid: 99, tree: tree } }
    end
    sup.define_singleton_method(:signal_shutdown_targets) { |_signal, _targets, **| nil }
    sup.define_singleton_method(:process_group_alive?) { |_pgid| false }
    sup.define_singleton_method(:reap_all) do
      reap_calls += 1
      if reap_calls == 1
        instance_variable_get(:@running).clear
        [ exit_entry ]
      else
        []
      end
    end

    with_replaced_singleton_method(
      Hive::ProcessKill, :captured_process_alive?, ->(_process) { false }
    ) do
      completed = sup.terminate_all(grace_sec: 1)

      assert_equal [ exit_entry ], completed
    end
    assert_equal 1, reap_calls
  end

  def test_capture_shutdown_targets_requires_a_stable_full_tree
    sup = make
    sup.instance_variable_set(:@running, {
      111 => {
        project: "p1", slug: "a", stage: "6-review", command: "hive run a",
        dry_run: false, pgid: 111
      }
    })
    original = [
      { pid: 222, ppid: 111, pgid: 222, start_time: "child", depth: 1 },
      { pid: 111, ppid: 1, pgid: 111, start_time: "root", depth: 0 }
    ]
    partial = [ original.last ]

    with_replaced_singleton_method(
      Hive::ProcessKill, :process_tree_snapshot, ->(_pid) { original }
    ) do
      with_replaced_singleton_method(
        Hive::ProcessKill, :confirm_process_tree_snapshot, ->(_pid, _targets) { partial }
      ) do
        captured = sup.send(:capture_shutdown_targets)
        assert_nil captured.fetch(111).fetch(:tree),
                   "a descendant disappearing between snapshots must fail closed"
      end
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

      completed = sup.terminate_all(grace_sec: 2)
      assert_equal 0, sup.in_flight_count, "TERM (with grace) must reap all running children"
      assert_equal 1, completed.size
      refute_equal Hive::ExitCodes::SUCCESS, completed.first.exit_code,
                   "a shutdown-interrupted child must not masquerade as success"
      assert_equal "a", completed.first.slug
    end
  end

  def test_terminate_all_kills_nested_descendant_before_returning_parent_exit
    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      descendant_path = File.join(dir, "descendant.pid")
      root_pid = sup.spawn(
        command_string: "hive run a --descendant-pid-file #{Shellwords.escape(descendant_path)} --sleep 30",
        project: "p1", slug: "a", stage: "refactor-patrol",
        dispatch_token: { kind: :architecture_patrol, job_id: "job-7" }
      )
      deadline = Time.now + 5
      sleep 0.01 until File.file?(descendant_path) || Time.now >= deadline
      assert File.file?(descendant_path), "fixture descendant did not start"
      descendant_pid = Integer(File.read(descendant_path))
      assert_equal descendant_pid, Process.getpgid(descendant_pid),
                   "fixture descendant must escape into its own process group"

      completed = sup.terminate_all(grace_sec: 0.2)

      assert_equal 1, completed.size
      assert_equal root_pid, completed.first.pid
      refute Hive::ProcessKill.pid_alive?(descendant_pid),
             "claim completion must wait until the nested descendant is gone"
    ensure
      Process.kill("KILL", descendant_pid) if descendant_pid && Hive::ProcessKill.pid_alive?(descendant_pid)
    end
  end

  def test_terminate_child_awaits_exact_group_and_preserves_dispatch_token_for_reap
    with_tmp_dir do |dir|
      sup = make(log_dir: dir)
      token = { kind: :architecture_patrol, job_id: "job-7", owner: "daemon", generation: 1 }
      pid = sup.spawn(
        command_string: "hive run a --exit-code 0 --sleep 30",
        project: "p1", slug: "a", stage: "refactor-patrol", dispatch_token: token
      )

      assert sup.terminate_child(pid, grace_sec: 1)
      completed = sup.reap_all
      assert_equal 1, completed.size
      assert_equal token, completed.first.dispatch_token
      assert_nil completed.first.exit_code, "signal termination must not masquerade as exit zero"
      assert_equal 0, sup.in_flight_count
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

  def test_terminate_child_escalates_to_kill_when_term_does_not_reap
    sup = make
    pid = 1234
    sup.instance_variable_set(:@running, {
      pid => {
        project: "p1", slug: "architecture", stage: "refactor-patrol",
        command: "hive refactor-patrol p1", started_at: Time.utc(2026, 7, 10),
        log_path: nil, dry_run: false, dispatch_token: { kind: :architecture_patrol }
      }
    })
    statuses = [ nil, Struct.new(:exitstatus).new(nil) ]
    kills = []
    sup.define_singleton_method(:pgid_for) { |_child_pid| 4321 }
    sup.define_singleton_method(:safe_kill) { |signal, target| kills << [ signal, target ] }
    sup.define_singleton_method(:wait_for_child) { |_child_pid, _seconds| statuses.shift }

    assert sup.terminate_child(pid, grace_sec: 0)
    assert_equal [ [ :TERM, -4321 ], [ :KILL, -4321 ] ], kills
    assert_equal pid, sup.reap_all.first.pid
  end

  def test_process_identity_requires_verified_start_time_and_process_group
    sup = make
    start_time = Hive::Lock.process_start_time(Process.pid)
    skip "process start identity unavailable" if start_time.to_s.empty?

    identity = sup.process_identity(Process.pid)

    assert_equal start_time.to_s, identity.fetch(:process_start_time)
    assert_operator identity.fetch(:pgid), :>, 1
    assert_nil sup.process_identity(nil)
    assert_nil sup.process_identity(1)

    with_replaced_singleton_method(Hive::Lock, :process_start_time, ->(_pid) { nil }) do
      assert_nil sup.process_identity(Process.pid)
    end
    with_replaced_singleton_method(Process, :getpgid, ->(_pid) { raise Errno::EPERM }) do
      assert_nil sup.process_identity(Process.pid)
    end
  end

  def test_wait_for_child_returns_nil_when_process_is_already_reaped
    sup = make
    with_replaced_singleton_method(Process, :wait2, ->(*_args) { raise Errno::ECHILD }) do
      assert_nil sup.send(:wait_for_child, 999_999, 0)
    end
  end

  def test_completion_envelope_reads_and_removes_job_bound_result_file
    with_tmp_dir do |dir|
      path = File.join(dir, "result.json")
      payload = { "schema" => "hive-refactor-patrol", "ok" => true }
      File.write(path, JSON.generate(payload))
      sup = make

      actual = sup.send(
        :completion_envelope,
        dispatch_token: { result_path: path }, log_path: nil
      )

      assert_equal payload, actual
      refute File.exist?(path), "the one-shot result artifact is consumed after completion"
    end
  end

  def test_parse_result_file_fails_closed_for_non_objects_and_malformed_json
    with_tmp_dir do |dir|
      path = File.join(dir, "result.json")
      sup = make
      File.write(path, JSON.generate([ "not", "an", "envelope" ]))
      assert_nil sup.send(:parse_result_file, path)

      File.write(path, "{")
      assert_nil sup.send(:parse_result_file, path)
      assert_nil sup.send(:parse_result_file, File.join(dir, "missing.json"))
    end
  end

  def test_log_path_fallback_uses_project_state_or_system_tmp_directory
    with_tmp_dir do |dir|
      sup = make

      state_path = sup.send(
        :log_path_for, project: "demo", slug: "architecture", log_state_path: dir
      )
      tmp_path = sup.send(
        :log_path_for, project: "demo", slug: "architecture", log_state_path: nil
      )

      assert state_path.start_with?(File.join(dir, "logs", "daemon-children", "demo", "architecture"))
      assert tmp_path.start_with?(File.join(Dir.tmpdir, "hive-daemon-logs", "demo", "architecture"))
      assert_equal "daemon-run.log", File.basename(state_path)
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
