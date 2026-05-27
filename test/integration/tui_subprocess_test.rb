require "test_helper"
require "securerandom"
require "tempfile"
require "hive/tui/subprocess"
require "hive/tui/subprocess_registry"

# Integration tests for `Hive::Tui::Subprocess.takeover_command(...)`,
# `Subprocess.run_quiet!`, and `SubprocessRegistry`. These exercise
# real `Process.spawn` / `Open3.capture3` against a small bash
# fixture so we cover the actual fork-exec, pgid lookup, wait, and
# trap save/restore paths the TUI relies on at runtime.
#
# Pre-U11 this file also tested `Subprocess.takeover!` (curses
# backend's full-screen takeover). U11 deleted the curses path;
# `takeover_command` now wraps the same spawn-and-wait core for
# the Bubble Tea runner.
class TuiSubprocessTest < Minitest::Test
  include HiveTestHelper

  FAKE_CHILD = File.expand_path("fixtures/tui-fake-child", __dir__).freeze

  def setup
    # Defensive: any previous test that crashed mid-flight could leave the
    # registry populated. Re-zeroing it keeps tests order-independent.
    Hive::Tui::SubprocessRegistry.clear
    %w[HIVE_TUI_FAKE_EXIT HIVE_TUI_FAKE_STDOUT HIVE_TUI_FAKE_STDERR
       HIVE_TUI_FAKE_TRAP_INT HIVE_TUI_FAKE_BLOCK].each { |k| ENV.delete(k) }
  end

  def teardown
    %w[HIVE_TUI_FAKE_EXIT HIVE_TUI_FAKE_STDOUT HIVE_TUI_FAKE_STDERR
       HIVE_TUI_FAKE_TRAP_INT HIVE_TUI_FAKE_BLOCK].each { |k| ENV.delete(k) }
    Hive::Tui::SubprocessRegistry.clear
  end

  def test_fixture_is_executable
    assert File.executable?(FAKE_CHILD), "fake child fixture must be executable"
  end

  def test_foreground_takeover_command_wraps_callable_with_alt_screen_sequence
    ran = false
    cmd = Hive::Tui::Subprocess.foreground_takeover_command(-> { ran = true })

    assert_kind_of Bubbletea::SequenceCommand, cmd
    assert_equal(
      [ Bubbletea::ExitAltScreenCommand, Bubbletea::ExecCommand, Bubbletea::EnterAltScreenCommand ],
      cmd.commands.map(&:class)
    )

    exec_cmd = cmd.commands.find { |c| c.is_a?(Bubbletea::ExecCommand) }
    exec_cmd.callable.call

    assert_equal true, ran
  end

  # Regression: an interactive child (vim/nvim/gh-pr-create-prompt)
  # spawned with `pgroup: true` lands in a non-foreground pgrp and
  # gets SIGTTIN on its first /dev/tty read — the symptom is "the
  # editor never appears". The takeover path must keep the child in
  # the parent's pgrp so reads succeed; SIGINT is silenced via the
  # parent trap, not via pgrp isolation. This test pins that contract
  # by using the real helper to spawn a child that asserts on its own
  # pgrp and inherited signal dispositions.
  def test_run_takeover_child_sync_keeps_child_in_parents_pgroup
    parent_pgrp = Process.getpgrp
    pgrp_capture = Tempfile.new("hive-tui-takeover-pgrp")
    pgrp_capture.close

    exit_code = Hive::Tui::Subprocess.run_takeover_child_sync(
      [ "ruby", "-e", "File.write(ARGV[0], Process.getpgrp.to_s)", pgrp_capture.path ]
    )
    inherited_pgrp = File.read(pgrp_capture.path).to_i

    assert_equal 0, exit_code
    assert_equal parent_pgrp, inherited_pgrp,
                 "takeover helper must spawn the child in the parent's pgrp"
  ensure
    pgrp_capture&.close
    pgrp_capture&.unlink
  end

  def test_run_takeover_child_sync_does_not_leak_ignored_signals_to_child
    signal_capture = Tempfile.new("hive-tui-takeover-signals")
    signal_capture.close
    child_script = <<~RUBY
      values = %w[INT QUIT TSTP].map { |signal| Signal.trap(signal, "DEFAULT").inspect }
      File.write(ARGV[0], values.join("\\n"))
    RUBY

    prev_int = Signal.trap("INT", "DEFAULT")
    prev_quit = Signal.trap("QUIT", "DEFAULT")
    prev_tstp = Signal.trap("TSTP", "DEFAULT")
    exit_code = Hive::Tui::Subprocess.run_takeover_child_sync(
      [ "ruby", "-e", child_script, signal_capture.path ]
    )
    child_handlers = File.read(signal_capture.path).lines(chomp: true)

    assert_equal 0, exit_code
    assert_equal %w["DEFAULT" "DEFAULT"], child_handlers.first(2),
                 "takeover helper must not make INT/QUIT inherit parent-side ignored traps"
    assert_includes %w["DEFAULT" "SYSTEM_DEFAULT"], child_handlers[2],
                    "takeover helper must leave TSTP at a stoppable default"
    refute_includes child_handlers, %("IGNORE"),
                    "takeover helper must not make children inherit parent-side ignored traps"
  ensure
    Signal.trap("INT", prev_int) if prev_int
    Signal.trap("QUIT", prev_quit) if prev_quit
    Signal.trap("TSTP", prev_tstp) if prev_tstp
    signal_capture&.close
    signal_capture&.unlink
  end

  def test_run_takeover_child_sync_restores_parent_terminal_signal_traps
    sentinel_int = proc { :sentinel_int }
    sentinel_quit = proc { :sentinel_quit }
    sentinel_tstp = proc { :sentinel_tstp }
    before_int = Signal.trap("INT", sentinel_int)
    before_quit = Signal.trap("QUIT", sentinel_quit)
    before_tstp = Signal.trap("TSTP", sentinel_tstp)
    begin
      exit_code = Hive::Tui::Subprocess.run_takeover_child_sync([ "ruby", "-e", "exit 0" ])
      after_int = Signal.trap("INT", "DEFAULT")
      after_quit = Signal.trap("QUIT", "DEFAULT")
      after_tstp = Signal.trap("TSTP", "DEFAULT")

      assert_equal 0, exit_code
      assert_same sentinel_int, after_int,
                  "run_takeover_child_sync must restore the parent's INT trap"
      assert_same sentinel_quit, after_quit,
                  "run_takeover_child_sync must restore the parent's QUIT trap"
      assert_same sentinel_tstp, after_tstp,
                  "run_takeover_child_sync must restore the parent's TSTP trap"
    ensure
      Signal.trap("INT", before_int)
      Signal.trap("QUIT", before_quit)
      Signal.trap("TSTP", before_tstp)
    end
  end

  # ---- run_quiet! ----

  def test_run_quiet_captures_stdout
    ENV["HIVE_TUI_FAKE_STDOUT"] = "hello-tui"
    exit_status, out, err = Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
    assert_equal 0, exit_status
    assert_equal "hello-tui", out
    assert_equal "", err
  end

  def test_run_quiet_captures_stderr_and_nonzero_status
    ENV["HIVE_TUI_FAKE_STDERR"] = "boom"
    ENV["HIVE_TUI_FAKE_EXIT"] = "3"
    exit_status, out, err = Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
    assert_equal 3, exit_status
    assert_equal "", out
    assert_equal "boom", err
  end

  # F9: run_quiet! no longer touches the global INT/TERM trap chain.
  # The previous install/restore pair only ever registered a
  # `:placeholder` pgid (register_real_pgid was never called from
  # this path), so the trap block always short-circuited and INT
  # forwarding silently no-op'd anyway. Removing the install/restore
  # also closes the concurrent-run_quiet! trap-chain race the
  # /ce-code-review walkthrough flagged.
  def test_run_quiet_does_not_modify_int_and_term_traps
    sentinel_int = proc { :sentinel_int }
    sentinel_term = proc { :sentinel_term }
    before_int = trap("INT", sentinel_int)
    before_term = trap("TERM", sentinel_term)
    begin
      Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
      after_int = trap("INT", "DEFAULT")
      after_term = trap("TERM", "DEFAULT")
      assert_same sentinel_int, after_int,
                  "run_quiet! must not overwrite the parent's INT trap"
      assert_same sentinel_term, after_term,
                  "run_quiet! must not overwrite the parent's TERM trap"
    ensure
      trap("INT", before_int)
      trap("TERM", before_term)
    end
  end

  def test_run_quiet_does_not_touch_subprocess_registry
    Hive::Tui::SubprocessRegistry.register_placeholder
    Hive::Tui::Subprocess.run_quiet!([ FAKE_CHILD ])
    assert_equal :placeholder, Hive::Tui::SubprocessRegistry.current,
      "run_quiet! must not write to or clear the registry — Open3 owns the child"
  ensure
    Hive::Tui::SubprocessRegistry.clear
  end

  def test_run_quiet_returns_command_not_found_sentinel_when_binary_missing
    exit_status, out, err = Hive::Tui::Subprocess.run_quiet!([ "/path/that/does/not/exist/hive-fake" ])
    assert_equal 127, exit_status
    assert_equal "", out
    assert_match(%r{command not found: /path/that/does/not/exist/hive-fake}, err)
  end

  # ---- SubprocessRegistry contract ----

  def test_registry_kill_inflight_is_noop_when_empty
    Hive::Tui::SubprocessRegistry.clear
    assert_nil Hive::Tui::SubprocessRegistry.kill_inflight!,
      "kill_inflight! on empty registry should be a no-op returning nil"
  end

  def test_registry_kill_inflight_is_noop_for_placeholder
    Hive::Tui::SubprocessRegistry.register_placeholder
    assert_nil Hive::Tui::SubprocessRegistry.kill_inflight!,
      "kill_inflight! on :placeholder should not raise and should clear"
    assert_nil Hive::Tui::SubprocessRegistry.current,
      "kill_inflight! should clear the slot even when placeholder"
  end

  def test_registry_register_overwrites_placeholder
    Hive::Tui::SubprocessRegistry.register_placeholder
    assert_equal :placeholder, Hive::Tui::SubprocessRegistry.current
    Hive::Tui::SubprocessRegistry.register(12_345)
    assert_equal 12_345, Hive::Tui::SubprocessRegistry.current
  ensure
    Hive::Tui::SubprocessRegistry.clear
  end
end

# `Subprocess.dispatch_background(argv, dispatch:)` spawns workflow-verb
# children in the background — TUI keeps rendering, multiple agents can
# run concurrently. A reaper Thread waits for each child and dispatches
# `Messages::SubprocessExited(verb:, exit_code:)` so the TUI flashes the
# result. The `dispatch:` lambda is the seam — App.run_charm wires
# `dispatch: runner.method(:send)`; tests pass a capture lambda + poll
# the captured-messages array for the reaper to fire.
class TuiSubprocessDispatchBackgroundTest < Minitest::Test
  include HiveTestHelper

  FAKE_CHILD = TuiSubprocessTest::FAKE_CHILD

  def setup
    Hive::Tui::SubprocessRegistry.clear
    %w[HIVE_TUI_FAKE_EXIT HIVE_TUI_FAKE_STDOUT HIVE_TUI_FAKE_STDERR
       HIVE_TUI_FAKE_TRAP_INT HIVE_TUI_FAKE_BLOCK].each { |k| ENV.delete(k) }
    @messages = []
    @messages_mutex = Mutex.new
    @dispatch = ->(msg) { @messages_mutex.synchronize { @messages << msg } }
  end

  def teardown
    %w[HIVE_TUI_FAKE_EXIT HIVE_TUI_FAKE_STDOUT HIVE_TUI_FAKE_STDERR
       HIVE_TUI_FAKE_TRAP_INT HIVE_TUI_FAKE_BLOCK].each { |k| ENV.delete(k) }
    Hive::Tui::SubprocessRegistry.clear
  end

  # Wait for the reaper Thread to dispatch `count` messages, up to
  # `timeout` seconds. Avoids fixed sleeps; matches the no-flake
  # rule from CLAUDE.md.
  def wait_for_messages(count, timeout: 3.0)
    deadline = Time.now + timeout
    while @messages_mutex.synchronize { @messages.length } < count
      return false if Time.now > deadline

      sleep 0.02
    end
    true
  end

  # ---- Builder shape ----

  def test_dispatch_background_returns_nil_and_does_not_block
    started = Time.now
    result = Hive::Tui::Subprocess.dispatch_background([ FAKE_CHILD, "pr" ], dispatch: @dispatch)
    elapsed = Time.now - started
    assert_nil result, "dispatch_background returns nil — no Bubbletea Cmd, the runner just keeps going"
    assert elapsed < 0.5, "dispatch must NOT wait for the child (got #{elapsed}s — should be < 0.5s)"
    wait_for_messages(1) # reap before teardown
  end

  # ---- Reaper Thread dispatches SubprocessExited ----

  def test_reaper_dispatches_subprocess_exited_with_zero_on_clean_exit
    Hive::Tui::Subprocess.dispatch_background([ FAKE_CHILD, "pr" ], dispatch: @dispatch)
    assert wait_for_messages(1), "reaper must dispatch SubprocessExited within 3s"
    msg = @messages.first
    assert_kind_of Hive::Tui::Messages::SubprocessExited, msg
    assert_equal "pr", msg.verb, "verb cached at argv[1] for the SubprocessExited flash"
    assert_equal 0, msg.exit_code
  end

  def test_reaper_dispatches_nonzero_exit_code
    ENV["HIVE_TUI_FAKE_EXIT"] = "7"
    Hive::Tui::Subprocess.dispatch_background([ FAKE_CHILD, "develop" ], dispatch: @dispatch)
    assert wait_for_messages(1)
    msg = @messages.first
    assert_equal 7, msg.exit_code
    assert_equal "develop", msg.verb
  end

  def test_reaper_dispatches_command_not_found_synchronously_when_binary_missing
    # ENOENT during spawn happens BEFORE we can hand off to the reaper —
    # `dispatch_background` itself dispatches the SubprocessExited so
    # the TUI gets immediate feedback rather than waiting on a phantom
    # reaper that has no child to wait for.
    result = Hive::Tui::Subprocess.dispatch_background(
      [ "/path/that/does/not/exist/hive-fake", "develop" ],
      dispatch: @dispatch
    )
    assert_equal false, result,
                 "spawn ENOENT must return a sentinel so recovery callers do not claim a rerun started"
    assert wait_for_messages(1, timeout: 0.5),
      "spawn ENOENT must dispatch SubprocessExited synchronously; no thread to wait on"
    msg = @messages.first
    assert_equal 127, msg.exit_code, "ENOENT translates to 127 (POSIX command-not-found)"
    assert_equal "develop", msg.verb
  end

  def test_reaper_dispatches_command_not_found_synchronously_when_binary_not_executable
    Tempfile.create("hive-tui-non-executable") do |file|
      file.write("#!/bin/sh\nexit 0\n")
      file.close
      File.chmod(0o600, file.path)

      result = Hive::Tui::Subprocess.dispatch_background([ file.path, "develop" ], dispatch: @dispatch)

      assert_equal false, result,
                   "spawn EACCES must return the same sentinel as ENOENT"
      assert wait_for_messages(1, timeout: 0.5),
        "spawn EACCES must dispatch SubprocessExited synchronously; no thread to wait on"
      msg = @messages.first
      assert_equal 127, msg.exit_code, "EACCES translates to the spawn-failure sentinel"
      assert_equal "develop", msg.verb
    end
  end

  def test_concurrent_dispatches_run_in_parallel
    # Two slow children, dispatched back-to-back. If `dispatch_background`
    # is truly non-blocking, both finish in ~max(t1, t2), not t1 + t2.
    ENV["HIVE_TUI_FAKE_BLOCK"] = "1"
    pids_killed = []
    pids_mutex = Mutex.new

    Hive::Tui::Subprocess.dispatch_background([ FAKE_CHILD, "develop" ], dispatch: @dispatch)
    Hive::Tui::Subprocess.dispatch_background([ FAKE_CHILD, "review" ], dispatch: @dispatch)

    # Kill any blocking child after a brief moment so the reapers can fire.
    killer = Thread.new do
      sleep 0.3
      `pgrep -f tui-fake-child`.split.each do |pid|
        Process.kill("TERM", pid.to_i)
        pids_mutex.synchronize { pids_killed << pid.to_i }
      rescue Errno::ESRCH
        nil
      end
    end

    assert wait_for_messages(2, timeout: 5.0),
      "both reapers must dispatch SubprocessExited; concurrent runs are the whole point"
    killer.join
    verbs = @messages.map(&:verb).sort
    assert_equal %w[develop review], verbs,
      "each dispatch must surface its own verb on completion (no cross-talk)"
  end

  # ---- Verb caching from argv[1] ----

  def test_verb_cached_from_argv_index_one
    Hive::Tui::Subprocess.dispatch_background(
      [ FAKE_CHILD, "brainstorm", "some-slug", "--from", "1-input" ],
      dispatch: @dispatch
    )
    assert wait_for_messages(1)
    assert_equal "brainstorm", @messages.first.verb
  end

  # ---- Per-spawn capture files (P2 #4) ----
  #
  # Pre-fix, child stdout/stderr was redirected to the shared
  # SUBPROCESS_LOG_PATH; rotation only fired around BEGIN/END stamps,
  # so a noisy child could grow the file past the cap before END
  # arrived. Per-spawn capture files give each spawn its own log
  # whose lifetime is bounded by the reaper (delete on success,
  # keep on failure). The disk-usage cap on the shared log is now
  # actually a real bound.

  def existing_spawn_capture_paths
    Dir.glob(File.join(Dir.tmpdir, "hive-tui-spawn-*.log"))
  end

  def test_dispatch_background_writes_child_stderr_to_per_spawn_capture
    ENV["HIVE_TUI_FAKE_STDERR"] = "fatal: synthetic failure for capture test"
    ENV["HIVE_TUI_FAKE_EXIT"] = "1"
    before = existing_spawn_capture_paths
    Hive::Tui::Subprocess.dispatch_background([ FAKE_CHILD, "pr" ], dispatch: @dispatch)
    assert wait_for_messages(1)

    # Failure path keeps the capture; new file shows up vs. baseline.
    after = existing_spawn_capture_paths
    new_files = after - before
    assert_equal 1, new_files.size,
      "failed spawn must leave exactly one new per-spawn capture for diagnose to read"
    captured = File.read(new_files.first)
    assert_includes captured, "fatal: synthetic failure for capture test",
      "child stderr must land in the per-spawn capture file, not the shared marker log"

    File.delete(new_files.first) # test cleanup
  end

  def test_successful_spawn_deletes_its_capture_file
    before = existing_spawn_capture_paths
    Hive::Tui::Subprocess.dispatch_background([ FAKE_CHILD, "pr" ], dispatch: @dispatch)
    assert wait_for_messages(1)

    after = existing_spawn_capture_paths
    assert_empty after - before,
      "exit 0 must delete its own per-spawn capture so disk usage is bounded by failures, not spawn count"
  end

  # NOTE: the diagnose-by-per-spawn-capture flow is pinned by
  # `test_per_spawn_diagnose_keeps_project_in_flash` in
  # test/unit/tui/subprocess_diagnose_test.rb, which uses synthetic
  # BEGIN lines + synthetic capture files via with_isolated_log.
  # An equivalent integration test using FAKE_CHILD wouldn't work:
  # the BEGIN argv would be the fake-child path, not "hive <verb>",
  # so recent_log_section_for's regex would never match. It would
  # only appear to pass when SUBPROCESS_LOG_PATH happened to contain
  # stale entries from real `hive pr` invocations in the dev env.

  def test_sweep_old_spawn_captures_deletes_orphans_past_cutoff
    # Drop a synthetic orphan dated 25h ago — older than the 24h cutoff.
    orphan = File.join(Dir.tmpdir, "hive-tui-spawn-#{SecureRandom.hex(4)}.log")
    File.write(orphan, "stale capture from a crashed reaper")
    File.utime(Time.now - (25 * 60 * 60), Time.now - (25 * 60 * 60), orphan)

    Hive::Tui::Subprocess.send(:sweep_old_spawn_captures!)

    refute File.exist?(orphan),
      "sweep_old_spawn_captures! must delete files older than SPAWN_CAPTURE_MAX_AGE_SECONDS"
  end

  def test_sweep_old_spawn_captures_keeps_recent_files
    # A file dated 1h ago is well within the 24h cutoff.
    keeper = File.join(Dir.tmpdir, "hive-tui-spawn-#{SecureRandom.hex(4)}.log")
    File.write(keeper, "recent capture from an in-flight reaper")
    File.utime(Time.now - (60 * 60), Time.now - (60 * 60), keeper)

    Hive::Tui::Subprocess.send(:sweep_old_spawn_captures!)

    assert File.exist?(keeper),
      "sweep must not touch captures within the cutoff window"
  ensure
    File.delete(keeper) if keeper && File.exist?(keeper)
  end
end
