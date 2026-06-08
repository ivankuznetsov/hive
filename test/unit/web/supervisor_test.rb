require "test_helper"
require "hive/web/supervisor"

# U8 container supervisor: the pure decision helpers — fast-failure backoff,
# the web-only-restart gate, and the SIGHUP reload that brings up the bot —
# carry the restart logic and must be pinned. start_child is stubbed (or fed a
# real quick-exit process) so no long-lived children are spawned.
class WebSupervisorTest < Minitest::Test
  include HiveTestHelper

  Child = Hive::Web::Supervisor::Child

  def build = Hive::Web::Supervisor.new

  def restart_at(sup) = sup.instance_variable_get(:@restart_at)

  def test_schedule_restart_backs_off_a_fast_failure
    with_tmp_global_config do
      sup = build
      child = Child.new(name: "web", argv: %w[x], pid: nil, started_at: Time.now)

      sup.send(:schedule_restart, child)

      assert_operator restart_at(sup)["web"], :>, Time.now + 1,
                      "a child that died almost immediately must be deferred (backoff)"
    end
  end

  def test_schedule_restart_is_immediate_for_a_long_lived_crash
    with_tmp_global_config do
      sup = build
      child = Child.new(name: "web", argv: %w[x], pid: nil, started_at: Time.now - 3600)

      sup.send(:schedule_restart, child)

      assert_operator restart_at(sup)["web"], :<=, Time.now + 0.5,
                      "a long-lived child that crashes restarts immediately"
    end
  end

  def test_reap_schedules_restart_for_every_crashed_child
    with_tmp_global_config do
      sup = build
      sup.send(:start_child, "web", [ "sh", "-c", "exit 1" ])
      sup.send(:start_child, "daemon", [ "sh", "-c", "exit 1" ])
      sup.send(:start_child, "bot", [ "sh", "-c", "exit 1" ])
      reap_until_drained(sup)

      assert restart_at(sup).key?("web"), "a failed web child must be scheduled for restart"
      assert restart_at(sup).key?("daemon"),
             "a crashed daemon must be restarted, not silently disappear"
      assert restart_at(sup).key?("bot"),
             "a crashed bot must be restarted, not silently disappear"
    end
  end

  def test_should_restart_skips_clean_exit_signal_death_and_shutdown
    with_tmp_global_config do
      sup = build
      crashed = run_status([ "sh", "-c", "exit 1" ])
      clean = run_status([ "true" ])
      signaled = run_status([ "sh", "-c", "kill -TERM $$" ])

      assert sup.send(:should_restart?, crashed), "a non-zero crash must restart"
      refute sup.send(:should_restart?, clean), "a clean (success) exit must NOT restart"
      refute sup.send(:should_restart?, signaled),
             "a signal death (e.g. SIGTERM during shutdown) must NOT respawn-then-re-kill"

      sup.instance_variable_set(:@stopping, true)
      refute sup.send(:should_restart?, crashed),
             "nothing is restarted once the supervisor is stopping"
    end
  end

  def test_reap_does_not_restart_a_clean_web_exit
    with_tmp_global_config do
      sup = build
      sup.send(:start_child, "web", [ "true" ])
      reap_until_drained(sup)

      refute restart_at(sup).key?("web"), "a clean (success) web exit must NOT be restarted"
    end
  end

  def test_handle_reload_starts_bot_when_enabled
    with_tmp_global_config do
      Hive::Config.update_global_config! do |data|
        data["bot"] = { "enabled" => true, "chat_id_allowlist" => [ 1 ] }
      end
      sup = build
      started = stub_start_child(sup)
      sup.instance_variable_set(:@reload_requested, true)

      sup.send(:handle_reload)

      assert_includes started, "bot", "SIGHUP reload with bot enabled must bring the bot up"
    end
  end

  def test_handle_reload_is_a_noop_when_bot_disabled
    with_tmp_global_config do
      sup = build
      started = stub_start_child(sup)

      sup.send(:handle_reload)

      refute_includes started, "bot", "reload must not start a bot the operator hasn't enabled"
    end
  end

  # P2: terminate_all must drain children CONCURRENTLY within one grace window,
  # not serially (children × grace), or Docker's 10s stop SIGKILLs the box.
  # Three children that each ignore SIGTERM and sleep must all be force-killed
  # within ~one grace window, not three.
  def test_terminate_all_drains_children_concurrently_within_one_grace_window
    with_tmp_global_config do
      Hive::Config.update_global_config! do |data|
        data["daemon"] = { "shutdown_grace_sec" => 2 }
      end
      sup = build
      # Children that IGNORE SIGTERM in-process (the whole process group, not a
      # forked `sleep` child) and keep running — forcing the SIGKILL escalation
      # in each reaper thread.
      ignore_term = "Signal.trap('TERM','IGNORE'); sleep 30"
      3.times do |i|
        sup.send(:start_child, "child#{i}", [ RbConfig.ruby, "-e", ignore_term ])
      end
      # Wait until each child has installed its trap, so terminate_all's TERM is
      # actually ignored (not delivered before the trap is set).
      wait_for_children_alive(sup)

      started = monotonic
      sup.send(:terminate_all)
      elapsed = monotonic - started

      assert_operator elapsed, :<, 4,
                      "3 children must drain within ~one 2s grace window (#{elapsed}s), " \
                      "not the serial sum (~6s+)"
      assert sup.instance_variable_get(:@children).all? { |c| reaped?(c.pid) },
             "every child process must be gone after terminate_all"
    end
  end

  def test_run_starts_children_traps_signals_and_terminates_on_stop
    with_env("HIVEBOX_SUPERVISOR_PID" => "outer") do
      published_pids = []
      with_tmp_global_config do
        sup = build
        started = []
        sup.define_singleton_method(:start_child) do |name, _argv|
          started << name
          published_pids << ENV["HIVEBOX_SUPERVISOR_PID"]
        end
        # Make the loop exit on its first iteration and turn terminate_all into a
        # no-op (no real children were spawned).
        sup.define_singleton_method(:terminate_all) { @terminated = true }
        sup.instance_variable_set(:@stopping, false)
        # Flip @stopping after the children start so the loop runs exactly once.
        sup.define_singleton_method(:reap_once) { @stopping = true }

        sup.run

        assert_includes started, "daemon", "run must start the daemon child"
        assert_includes started, "web", "run must start the web child"
        assert_equal [ Process.pid.to_s, Process.pid.to_s ], published_pids,
                     "run must publish its pid before children are spawned"
        assert sup.instance_variable_get(:@terminated), "run must terminate_all on exit"
        assert_equal "outer", ENV["HIVEBOX_SUPERVISOR_PID"],
                     "run must restore the caller's supervisor pid when it exits"
      end
    end
  end

  def test_run_starts_bot_when_enabled
    with_tmp_global_config do
      Hive::Config.update_global_config! do |data|
        data["bot"] = { "enabled" => true, "chat_id_allowlist" => [ 1 ] }
      end
      sup = build
      started = stub_start_child(sup)
      sup.define_singleton_method(:terminate_all) { nil }
      sup.define_singleton_method(:reap_once) { @stopping = true }

      sup.run

      assert_includes started, "bot", "run must start the bot when it is enabled"
    end
  end

  def test_trap_signals_marks_stopping_and_reload
    with_tmp_global_config do
      sup = build
      sup.send(:trap_signals)
      begin
        Process.kill("HUP", Process.pid)
        # Give the trap a beat to fire.
        sleep 0.05
        assert sup.instance_variable_get(:@reload_requested),
               "SIGHUP must request a reload"
      ensure
        # Restore default handlers so we don't leak traps into other tests.
        %w[TERM INT HUP].each { |s| Signal.trap(s, "DEFAULT") }
      end
    end
  end

  def test_start_child_rebinds_an_existing_child_on_restart
    with_tmp_global_config do
      sup = build
      sup.send(:start_child, "web", [ "sleep", "30" ])
      first = sup.instance_variable_get(:@children).first.pid
      sup.send(:start_child, "web", [ "sleep", "30" ])
      children = sup.instance_variable_get(:@children)

      assert_equal 1, children.size, "a restart must rebind the existing child, not append"
      refute_equal first, children.first.pid, "the rebind must record the new pid"
    ensure
      children = sup.instance_variable_get(:@children)
      children.each { |c| Process.kill("KILL", -c.pid) rescue nil; Process.waitpid(c.pid) rescue nil }
    end
  end

  def test_start_due_restarts_respawns_only_due_entries_and_not_while_stopping
    with_tmp_global_config do
      sup = build
      sup.send(:start_child, "web", [ "true" ])
      reap_until_drained(sup)
      restart_at(sup)["web"] = Time.now - 1     # due
      restart_at(sup)["bot"] = Time.now + 3600   # not due

      started = []
      sup.define_singleton_method(:start_child) { |name, _argv| started << name }
      sup.send(:start_due_restarts)

      assert_includes started, "web", "a due restart must respawn"
      refute restart_at(sup).key?("web"), "a fired restart must be cleared"
      refute_includes started, "bot", "a not-yet-due restart must wait"

      sup.instance_variable_set(:@stopping, true)
      started.clear
      restart_at(sup)["web2"] = Time.now - 1
      sup.send(:start_due_restarts)
      assert_empty started, "no restarts may fire while stopping"
    end
  end

  def test_reap_once_clears_pid_when_child_already_reaped
    with_tmp_global_config do
      sup = build
      sup.send(:start_child, "web", [ "true" ])
      child = sup.instance_variable_get(:@children).first
      Process.waitpid(child.pid) # steal the reap → reap_once hits Errno::ECHILD

      sup.send(:reap_once)

      assert_nil child.pid, "an already-reaped child must have its pid cleared (ECHILD path)"
    end
  end

  def test_force_kill_is_a_noop_when_child_already_gone
    with_tmp_global_config do
      sup = build
      pid = Process.spawn("true")
      Process.waitpid(pid)
      child = Child.new(name: "web", argv: %w[x], pid: pid, started_at: Time.now)

      # Must swallow ESRCH/ECHILD on a child that is already gone.
      assert_nil sup.send(:force_kill, child),
                 "force_kill on a dead child must be a benign no-op"
    end
  end

  def test_terminate_all_tolerates_a_group_that_is_already_gone
    with_tmp_global_config do
      sup = build
      pid = Process.spawn("true")
      Process.waitpid(pid) # group is gone → the broadcast TERM raises ESRCH
      sup.instance_variable_get(:@children) <<
        Child.new(name: "web", argv: %w[x], pid: pid, started_at: Time.now)

      # Must not raise even though the initial TERM hits a dead group.
      sup.send(:terminate_all)
    end
  end

  def test_reap_with_escalation_tolerates_echild_on_wait
    with_tmp_global_config do
      sup = build
      pid = Process.spawn("true")
      Process.waitpid(pid) # already reaped → Process.waitpid raises Errno::ECHILD
      child = Child.new(name: "web", argv: %w[x], pid: pid, started_at: Time.now)

      # Must swallow the ECHILD instead of bubbling it out of the reaper thread.
      assert_nil sup.send(:reap_with_escalation, child, 1),
                 "an already-reaped child must not blow up the escalation reaper"
    end
  end

  def test_reap_with_escalation_returns_when_child_exits_cleanly
    with_tmp_global_config do
      sup = build
      pid = Process.spawn("true")
      child = Child.new(name: "web", argv: %w[x], pid: pid, started_at: Time.now)

      # Child exits on its own well within the window → reaped, no force kill.
      sup.send(:reap_with_escalation, child, 5)

      assert_equal true, reaped?(pid), "a cleanly-exiting child is reaped within the window"
    end
  end

  # P0-1: loading hive/web/supervisor WITHOUT a preceding `require "hive"` must
  # not raise NameError (uninitialized Hive::ConfigError). test_helper.rb
  # requires "hive" first and masks this, so assert it in a fresh subprocess.
  def test_supervisor_loads_standalone_without_a_preceding_require_hive
    lib = File.expand_path("../../../../lib", __FILE__)
    script = 'require "hive/web/supervisor"; print Hive::Web::Supervisor.name'
    out = IO.popen([ RbConfig.ruby, "-I", lib, "-e", script ], err: %i[child out], &:read)

    assert_equal 0, $?.exitstatus,
                 "supervisor must load standalone (entrypoint does `ruby -rhive...`): #{out}"
    assert_equal "Hive::Web::Supervisor", out, "expected a clean load with no NameError: #{out}"
  end

  private

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def run_status(argv)
    pid = Process.spawn(*argv)
    _, status = Process.waitpid2(pid)
    status
  end

  def wait_for_children_alive(sup)
    deadline = monotonic + 5
    children = sup.instance_variable_get(:@children)
    loop do
      break if children.all? { |c| c.pid && process_running?(c.pid) }
      flunk "children did not start" if monotonic > deadline

      sleep 0.05
    end
    # Give each child a beat to install its TERM trap before we signal.
    sleep 0.3
  end

  def process_running?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::ECHILD
    false
  end

  def reaped?(pid)
    return true if pid.nil?

    Process.kill(0, pid)
    false
  rescue Errno::ESRCH, Errno::ECHILD
    true
  end

  def stub_start_child(sup)
    started = []
    sup.define_singleton_method(:start_child) { |name, _argv| started << name }
    started
  end

  # Drive reap_once until both children have been collected (or a deadline),
  # without a fixed sleep that would race the child exits.
  def reap_until_drained(sup)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      sup.send(:reap_once)
      children = sup.instance_variable_get(:@children)
      break if children.all? { |c| c.pid.nil? }
      flunk "children did not exit within deadline" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.02
    end
  end
end
