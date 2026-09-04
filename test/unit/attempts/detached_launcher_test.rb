require "test_helper"
require "hive/attempts/detached_launcher"

class AttemptsDetachedLauncherTest < Minitest::Test
  include HiveTestHelper

  CLAIM_CAPABILITY = "c" * 64

  def test_detached_wrapper_claims_in_new_session_and_finishes_without_daemon
    skip "POSIX fork/setsid unavailable" unless Hive::Attempts::DetachedLauncher.supported?

    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      attempt = store.create_launching(
        attempt_id: "attempt-detached", request_id: "request-1",
        task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
        task_generation: "generation-1", progress_token: "progress", provider: "codex",
        worker_argv: [ "/bin/sh", "-c", "printf detached" ],
        claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
        starting_revision: nil, retry_charge: 0, inherited_outputs: [],
        launch_timeout_sec: 5, now: Time.now.utc
      )
      caller_sid = Process.getsid(0)
      launcher = Hive::Attempts::DetachedLauncher.new(
        store: store, heartbeat_sec: 0.02, stale_sec: 1,
        first_heartbeat_timeout_sec: 1, ready_timeout_sec: 2,
        systemd_scope: -> { false }
      )

      handoff = launcher.launch(attempt, claim_capability: CLAIM_CAPABILITY)
      assert_equal true, handoff.fetch("claimed")

      terminal = wait_for_terminal(store, attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      refute_equal caller_sid, terminal.wrapper.fetch("session_id")
      assert_equal terminal.wrapper.fetch("session_id"), terminal.wrapper.fetch("process_group_id")
    end
  end

  def test_linux_user_manager_places_the_live_wrapper_in_a_sibling_scope
    skip "systemd user scopes unavailable" unless
      Hive::Attempts::DetachedLauncher.systemd_scope_available?

    with_tmp_dir do |root|
      store = Hive::Attempts::Repository.new(root: root, migrate: true)
      attempt = store.create_launching(
        attempt_id: "attempt-systemd-scope", request_id: "request-scope",
        task_id: "42", project: "demo",
        task_slug: "task", intended_stage: "4-execute",
        task_generation: "generation-1", progress_token: "progress",
        provider: "codex", worker_argv: [ "/bin/sleep", "1" ],
        claim_capability_digest: Hive::Attempts::Capability.digest(CLAIM_CAPABILITY),
        starting_revision: nil, retry_charge: 0, inherited_outputs: [],
        launch_timeout_sec: 5, now: Time.now.utc
      )
      launcher = Hive::Attempts::DetachedLauncher.new(
        store: store, heartbeat_sec: 0.02, stale_sec: 1,
        first_heartbeat_timeout_sec: 1, ready_timeout_sec: 2
      )

      handoff = launcher.launch(attempt, claim_capability: CLAIM_CAPABILITY)
      assert_equal true, handoff.fetch("claimed")
      wrapper_pid = store.fetch(attempt.attempt_id).wrapper.fetch("pid")
      wrapper_cgroup = File.read("/proc/#{wrapper_pid}/cgroup")
      refute_equal File.read("/proc/self/cgroup"), wrapper_cgroup
      assert_match(/hive-attempt-[0-9a-f]{24}\.scope/, wrapper_cgroup)
      assert_equal "succeeded", wait_for_terminal(store, attempt.attempt_id).outcome
    end
  end

  def test_preflight_rejects_when_platform_adapter_is_unavailable
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: Object.new, capability: -> { false }
    )
    error = assert_raises(Hive::Attempts::UnsupportedDetachment) { launcher.preflight! }
    assert_includes error.message, "detached"
  end

  def test_systemd_scope_probe_falls_back_when_the_user_bus_cannot_be_inspected
    with_replaced_singleton_method(File, :socket?, ->(_path) { raise Errno::EACCES }) do
      refute Hive::Attempts::DetachedLauncher.systemd_scope_available?
    end
  end

  def test_launch_timeout_leaves_an_expirable_launching_reservation
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: launcher_store, ready_timeout_sec: 0
    )
    record = Struct.new(:attempt_id).new("attempt-timeout")
    launcher.define_singleton_method(:fork) { 321 }

    with_replaced_singleton_method(Process, :wait, ->(_pid) { }) do
      with_replaced_singleton_method(IO, :select, ->(*_args) { nil }) do
        result = launcher.launch(record, claim_capability: CLAIM_CAPABILITY)
        assert_equal false, result.fetch("claimed")
        assert_equal "launching", result.fetch("state")
      end
    end
  end

  def test_launcher_reports_setsid_failure_before_wrapper_fork
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: launcher_store, systemd_scope: -> { false }
    )
    record = Struct.new(:attempt_id).new("attempt-failed")
    launcher.define_singleton_method(:fork) { |&block| block.call }
    launcher.define_singleton_method(:exit!) { |_status| throw :launcher_exited, :launcher_exited }

    with_replaced_singleton_method(Process, :setsid, -> { raise Errno::EPERM }) do
      with_replaced_singleton_method(IO, :pipe, -> { [ StringIO.new, StringIO.new ] }) do
        assert_equal :launcher_exited, catch(:launcher_exited) {
          launcher.launch(record, claim_capability: CLAIM_CAPABILITY)
          flunk "launcher did not exit"
        }
      end
    end
  end

  def test_launcher_invokes_wrapper_after_session_creation
    launcher = Hive::Attempts::DetachedLauncher.new(store: launcher_store)
    record = Struct.new(:attempt_id).new("attempt-child")
    invoked = nil
    launcher.define_singleton_method(:fork) { |&block| block.call }
    launcher.define_singleton_method(:fork_wrapper) do |seen_record, capability, _writer, **|
      invoked = [ seen_record, capability ]
    end
    launcher.define_singleton_method(:exit!) { |_status| throw :launcher_exited }

    with_replaced_singleton_method(Process, :setsid, -> { 123 }) do
      with_replaced_singleton_method(IO, :pipe, -> { [ StringIO.new, StringIO.new ] }) do
        catch(:launcher_exited) { launcher.launch(record, claim_capability: CLAIM_CAPABILITY) }
      end
    end
    assert_equal [ record, CLAIM_CAPABILITY ], invoked
  end

  def test_wrapper_exec_contains_timers_timeout_and_worker_command
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: launcher_store, timeout_sec: 12, systemd_scope: -> { false }
    )
    record = Struct.new(:attempt_id).new("attempt-command")
    executed = nil
    launcher.define_singleton_method(:fork) do |&block|
      block.call
      999
    end
    launcher.define_singleton_method(:exec) { |*args, **kwargs| executed = [ args, kwargs ] }
    reader, writer = IO.pipe

    assert_equal 999, launcher.send(:fork_wrapper, record, CLAIM_CAPABILITY, writer)
    args, kwargs = executed
    assert_equal "attempt-command", args[4]
    assert_includes args, "--timeout-sec"
    assert_equal "12", args[args.index("--timeout-sec") + 1]
    refute_includes args, "/bin/echo"
    refute_includes args, "ok"
    claim_fd = args.first.fetch("HIVE_ATTEMPT_CLAIM_FD")
    assert Integer(claim_fd).positive?
    assert_equal true, kwargs.fetch(:close_others)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def test_wrapper_exec_constructs_trusted_rubylib_for_hive_self_reentry
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: launcher_store, systemd_scope: -> { false }
    )
    record = Struct.new(:attempt_id).new("attempt-rubylib")
    executed = nil
    launcher.define_singleton_method(:fork) do |&block|
      block.call
      999
    end
    launcher.define_singleton_method(:exec) { |*args, **kwargs| executed = [ args, kwargs ] }
    reader, writer = IO.pipe

    with_env(
      "RUBYLIB" => "/untrusted/checkout/lib",
      "BUNDLE_GEMFILE" => "/untrusted/checkout/Gemfile"
    ) do
      launcher.send(:fork_wrapper, record, CLAIM_CAPABILITY, writer)
    end

    environment = executed.first.first
    assert_equal launcher.send(:trusted_runtime_load_path), environment.fetch("RUBYLIB")
    refute_includes environment.fetch("RUBYLIB"), "/untrusted/checkout/lib"
    assert_nil environment.fetch("BUNDLE_GEMFILE")
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def test_wrapper_exec_uses_a_sibling_systemd_scope_without_losing_handshake_fds
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: launcher_store,
      systemd_scope: -> { true }, systemd_run: "/usr/bin/systemd-run"
    )
    record = Struct.new(:attempt_id).new("attempt-command")
    executed = nil
    launcher.define_singleton_method(:fork) do |&block|
      block.call
      999
    end
    launcher.define_singleton_method(:exec) { |*args, **kwargs| executed = [ args, kwargs ] }
    reader, writer = IO.pipe

    assert_equal 999, launcher.send(
      :fork_wrapper, record, CLAIM_CAPABILITY, writer, use_systemd_scope: true
    )
    args, kwargs = executed
    assert_equal "/usr/bin/systemd-run", args[1]
    assert_includes args, "--user"
    assert_includes args, "--scope"
    assert_includes args, "--collect"
    assert_includes args, "--unit=hive-attempt-5a3f8270644f411031e77d7f"
    ruby_index = args.index(RbConfig.ruby)
    refute_nil ruby_index
    assert_equal "__attempt-supervise", args[ruby_index + 2]
    claim_fd = args.first.fetch("HIVE_ATTEMPT_CLAIM_FD")
    ready_fd = args.first.fetch("HIVE_ATTEMPT_READY_FD")
    assert_equal claim_fd.to_i, kwargs.keys.grep(Integer).find { |fd| fd == claim_fd.to_i }
    assert_equal ready_fd.to_i, kwargs.keys.grep(Integer).find { |fd| fd == ready_fd.to_i }
    assert_equal true, kwargs.fetch(:close_others)
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  def test_exec_delegates_to_the_process_guard
    launcher = Hive::Attempts::DetachedLauncher.new(store: launcher_store)
    call = nil
    with_replaced_singleton_method(
      Hive::RuntimeControlPlane::ProcessGuard, :exec,
      ->(*arguments, **options) { call = [ arguments, options ]; :executed }
    ) do
      assert_equal :executed, launcher.send(:exec, "hive", "version", close_others: true)
    end
    assert_equal [ [ "hive", "version" ], { close_others: true } ], call
  end

  private

  def launcher_store
    database = Struct.new(:path).new("/state/runtime-control-plane.sqlite3")
    Struct.new(:root, :database).new("/attempts", database)
  end

  def wait_for_terminal(store, attempt_id)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    loop do
      record = store.fetch(attempt_id)
      return record if record&.final?
      raise "attempt did not finish" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.01
    end
  end
end
