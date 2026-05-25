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
