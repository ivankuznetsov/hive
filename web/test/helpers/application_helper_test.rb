require "test_helper"

class ApplicationHelperTest < ActionView::TestCase
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
