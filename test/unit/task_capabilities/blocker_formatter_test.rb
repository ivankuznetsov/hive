require "test_helper"
require "shellwords"
require "hive/task_capabilities/blocker_formatter"

class TaskCapabilitiesBlockerFormatterTest < Minitest::Test
  def test_preview_and_captured_recovery_share_text_and_shell_safe_corrections
    blocker = { "capability" => "qa", "reason" => "task_capability_verification_unavailable", "message" => "QA has no usable behavior check" }
    expected = { "expected_identity" => { "slug" => "a task" }, "expected_version" => 2, "expected_sha" => "a" * 40 }
    value = Hive::TaskCapabilities::BlockerFormatter.new(target: "a task", project: "demo space", expected: expected).call(blocker)
    assert_includes value.fetch("message"), blocker.fetch("message")
    assert_includes value.fetch("message"), "declare a usable check"
    argv = Shellwords.split(value.fetch("command"))
    assert_equal [ "hive", "task-capabilities", "propose", "a task", "--project", "demo space" ], argv.first(6)
    assert_equal JSON.generate(expected.fetch("expected_identity")), argv[argv.index("--identity") + 1]
    assert_includes value.fetch("alternative_command"), "--checks all"
    preview = Hive::TaskCapabilities::BlockerFormatter.new.call(blocker)
    assert_equal value.fetch("message"), preview.fetch("message")
    assert_includes preview.fetch("command"), "task-capabilities propose"
  end

  def test_security_unavailable_never_suggests_removal_or_finalization
    value = Hive::TaskCapabilities::BlockerFormatter.new.call({ "capability" => "security", "reason" => "task_capability_route_unavailable", "message" => "Approved route is offline" })
    assert_includes value.fetch("message"), "restore the exact approved route or archive/cancel"
    assert_nil value.fetch("command")
    refute_includes value.fetch("message"), "fallback"
  end

  def test_prerequisites_name_the_exact_operator_correction_path
    formatter = Hive::TaskCapabilities::BlockerFormatter.new
    %w[approval_required approval_scope missing_skill policy_conflict blocked].each do |suffix|
      value = formatter.call("capability" => "security", "reason" => "task_capability_#{suffix}", "message" => "Missing prerequisite")
      assert_includes value.fetch("message"), "Missing prerequisite"
      argv = Shellwords.split(value.fetch("command"))
      assert_equal [ "hive", "task-capabilities" ], argv.first(2)
      if suffix.start_with?("approval")
        assert_includes argv, "security=<REFERENCE>"
        assert_includes Shellwords.split(value.fetch("alternative_command")), "security=<CAPTURED_REFERENCE>"
      end
    end
    custom = formatter.call("capability_id" => "audit", "reason" => "task_capability_verification_unavailable")
    assert_nil custom.fetch("alternative_command")
    refute_includes custom.fetch("message"), "QA waiver"
  end
end
