require "eval/eval_helper"

class HiveEvalCliCaptureTest < Minitest::Test
  def test_fake_child_supervisor_captures_command_and_configured_stdout
    child = Hive::Eval::FakeChildSupervisor.new
    envelope = { "schema" => "hive-status", "ok" => true }
    child.respond_to([ "hive", "run", Hive::Eval::FakeChildSupervisor.anything, "--json" ])
         .with_stdout(JSON.generate(envelope), exit_status: 0)

    pid = child.dispatch(
      command_argv: [ "hive", "run", "slug-a", "--json" ],
      cwd: "/tmp/project",
      chat_id: 12345,
      update_id: 7,
      project: "hive",
      slug: "slug-a"
    )

    dispatch = child.dispatches.fetch(0)
    assert_equal [ "hive", "run", "slug-a", "--json" ], dispatch.command_argv
    assert_equal JSON.generate(envelope), dispatch.stdout
    assert_equal 0, child.completed_exit(pid).exit_code
    assert_equal envelope, child.completed_exit(pid).json_envelope
  end

  def test_harness_callback_dispatch_is_captured
    harness = Hive::Eval::Harness.new

    harness.when_user_taps("approve:plan:hive:slug-a:2-brainstorm")

    assert_equal [ "hive", "plan", "slug-a", "--from", "2-brainstorm",
                   "--project", "hive", "--json" ], harness.child_supervisor.commands.last
    assert_equal "Queued command pid=20001", harness.last_sent.text
  end
end
