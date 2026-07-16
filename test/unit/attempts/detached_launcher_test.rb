require "test_helper"
require "hive/attempts/detached_launcher"

class AttemptsDetachedLauncherTest < Minitest::Test
  include HiveTestHelper

  def test_detached_wrapper_claims_in_new_session_and_finishes_without_daemon
    skip "POSIX fork/setsid unavailable" unless Hive::Attempts::DetachedLauncher.supported?

    with_tmp_dir do |root|
      store = Hive::Attempts::Store.new(root: root)
      attempt = store.create_launching(
        attempt_id: "attempt-detached", request_id: "request-1", predecessor_attempt_id: nil,
        task_id: "42", project: "demo", task_slug: "task", intended_stage: "4-execute",
        task_generation: "generation-1", progress_token: "progress", provider: "codex",
        starting_revision: nil, retry_charge: 0, inherited_outputs: [],
        launch_timeout_sec: 5, now: Time.now.utc
      )
      caller_sid = Process.getsid(0)
      launcher = Hive::Attempts::DetachedLauncher.new(
        store: store, heartbeat_sec: 0.02, stale_sec: 1,
        first_heartbeat_timeout_sec: 1, ready_timeout_sec: 2
      )

      handoff = launcher.launch(attempt, argv: [ "/bin/sh", "-c", "printf detached" ])
      assert_equal true, handoff.fetch("claimed")

      terminal = wait_for_terminal(store, attempt.attempt_id)
      assert_equal "succeeded", terminal.outcome
      refute_equal caller_sid, terminal.wrapper.fetch("session_id")
      assert_equal terminal.wrapper.fetch("session_id"), terminal.wrapper.fetch("process_group_id")
    end
  end

  def test_preflight_rejects_when_platform_adapter_is_unavailable
    launcher = Hive::Attempts::DetachedLauncher.new(
      store: Object.new, capability: -> { false }
    )
    error = assert_raises(Hive::Attempts::UnsupportedDetachment) { launcher.preflight! }
    assert_includes error.message, "detached"
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
