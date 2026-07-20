require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
  test "status dots follow the core dominant state" do
    expected = {
      "needs-you" => "error", "error" => "error", "recovery" => "waiting",
      "running" => "running", "blocked" => "waiting", "ready" => "waiting", "idle" => "idle"
    }

    expected.each do |dominant_state, dot_kind|
      html = status_dot(
        "dominant_state" => dominant_state, "marker" => "error",
        "action" => "error", "claude_pid_alive" => dominant_state != "running"
      )
      assert_includes html, "status-dot-#{dot_kind}", "dominant state #{dominant_state.inspect}"
    end
  end

  test "coding row maps its stage index to the coding verb" do
    task = { "stage" => "2-brainstorm" } # no workflow key = coding
    assert_equal "ready_to_brainstorm", stage_dispatch_action(task)
    assert_equal "brainstorm", stage_run_verb(task)
  end

  test "non-coding runnable row dispatches the generic run, not a coding verb" do
    task = { "stage" => "2-research", "workflow" => "content_fixture", "action" => "ready_to_run" }
    assert_equal "ready_to_run", stage_dispatch_action(task),
                 "a content stage must route through the dispatcher's ready_to_run path"
    assert_equal "stage", stage_run_verb(task)
  end

  test "non-coding non-runnable row offers no manual run (Approve handles advance)" do
    task = { "stage" => "2-research", "workflow" => "content_fixture", "action" => "ready_to_advance" }
    assert_nil stage_dispatch_action(task)
    assert_nil stage_run_verb(task)
  end
end
