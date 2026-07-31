require "test_helper"
require "hive/attempts/detached_launcher"
require "hive/modules/migration/qualification_process_custody"

class AttemptsDetachedLauncherTest < Minitest::Test
  include HiveTestHelper

  CLAIM_CAPABILITY = "c" * 64

  def test_detached_wrapper_claims_in_new_session_and_finishes_without_daemon
    skip "POSIX fork/setsid unavailable" unless Hive::Attempts::DetachedLauncher.supported?

    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      custody_root = File.join(root, "qualification-custody")
      FileUtils.mkdir_p(custody_root, mode: 0o700)
      attempt = store.create_launching(
        attempt_id: "11111111-1111-4111-8111-111111111111",
        request_id: "request-1", predecessor_attempt_id: nil,
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
        first_heartbeat_timeout_sec: 1, ready_timeout_sec: 2
      )

      handoff = with_env(
        "HIVE_QUALIFICATION_CUSTODY_ROOT" => custody_root
      ) do
        launcher.launch(
          attempt,
          claim_capability: CLAIM_CAPABILITY
        )
      end
      assert_equal true, handoff.fetch("claimed")

      terminal = wait_for_terminal(store, attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      refute_equal caller_sid, terminal.wrapper.fetch("session_id")
      assert_equal terminal.wrapper.fetch("session_id"), terminal.wrapper.fetch("process_group_id")
      custody =
        Hive::Modules::Migration::
          QualificationProcessCustody.read_all(
            root: custody_root
          ).fetch(attempt.attempt_id)
      assert_equal terminal.wrapper,
                   custody.fetch("wrapper")
    end
  end

  def test_preflight_rejects_when_platform_adapter_is_unavailable
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: Object.new, capability: -> { false }
    )
    error = assert_raises(Hive::Attempts::UnsupportedDetachment) { launcher.preflight! }
    assert_includes error.message, "detached"
  end

  def test_launch_timeout_leaves_an_expirable_launching_reservation
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: Struct.new(:root).new("/attempts"), ready_timeout_sec: 0
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
    launcher = Hive::Attempts::DetachedLauncher.new(store: Struct.new(:root).new("/attempts"))
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
    launcher = Hive::Attempts::DetachedLauncher.new(store: Struct.new(:root).new("/attempts"))
    record = Struct.new(:attempt_id).new("attempt-child")
    invoked = nil
    launcher.define_singleton_method(:fork) { |&block| block.call }
    launcher.define_singleton_method(:fork_wrapper) do |seen_record, capability, _writer|
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
      store: Struct.new(:root).new("/attempts"), timeout_sec: 12
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

  private

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
