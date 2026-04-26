require "test_helper"
require "ostruct"
require "hive/task_action"
require "hive/markers"

# Pin Hive::TaskAction's classification matrix and command-emission rules.
# This module is the central decision point for `hive status` action
# grouping and `next_action.command` strings emitted by every other
# command, so a typo in ACTIONS would silently misroute agents.
class TaskActionTest < Minitest::Test
  Marker = Hive::Markers::State

  def fake_task(stage_name:, stage_index:, slug: "demo-260426-aaaa", project_root: "/x")
    OpenStruct.new(stage_name: stage_name, stage_index: stage_index, slug: slug,
                   project_root: project_root, project_name: File.basename(project_root))
  end

  def marker(name, attrs = {})
    Marker.new(name: name, attrs: attrs, raw: nil)
  end

  # ── classification matrix ─────────────────────────────────────────────

  def test_inbox_marker_waiting_is_ready_to_brainstorm
    task = fake_task(stage_name: "inbox", stage_index: 1)
    action = Hive::TaskAction.for(task, marker(:waiting))
    assert_equal "ready_to_brainstorm", action.key
    assert_equal "Ready to brainstorm", action.label
  end

  def test_brainstorm_complete_is_ready_to_plan
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_equal "ready_to_plan", action.key
    assert_equal "Ready to plan", action.label
  end

  def test_brainstorm_waiting_is_needs_input
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    assert_equal "needs_input", Hive::TaskAction.for(task, marker(:waiting)).key
  end

  def test_plan_complete_is_ready_to_develop
    task = fake_task(stage_name: "plan", stage_index: 3)
    assert_equal "ready_to_develop", Hive::TaskAction.for(task, marker(:complete)).key
  end

  def test_execute_complete_is_ready_for_pr
    task = fake_task(stage_name: "execute", stage_index: 4)
    assert_equal "ready_for_pr", Hive::TaskAction.for(task, marker(:execute_complete)).key
  end

  def test_execute_waiting_with_findings_is_review_findings
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:execute_waiting, "findings_count" => 3))
    assert_equal "review_findings", action.key
    assert_equal "Review findings", action.label
  end

  def test_execute_waiting_no_findings_is_needs_input
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:execute_waiting, "findings_count" => 0))
    assert_equal "needs_input", action.key
  end

  def test_pr_complete_is_ready_to_archive
    task = fake_task(stage_name: "pr", stage_index: 5)
    assert_equal "ready_to_archive", Hive::TaskAction.for(task, marker(:complete)).key
  end

  def test_done_is_archived_with_no_command
    task = fake_task(stage_name: "done", stage_index: 6)
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_equal "archived", action.key
    assert_nil action.command, "archived state has no runnable command"
  end

  # ── carve-outs ─────────────────────────────────────────────────────────

  def test_agent_working_marker_overrides_every_stage
    # Surfacing a workflow command for an in-flight agent would send
    # retry loops into ConcurrentRunError. Always agent_running, no command.
    %w[brainstorm plan execute pr].each do |stage|
      task = fake_task(stage_name: stage, stage_index: %w[inbox brainstorm plan execute pr done].index(stage) + 1)
      action = Hive::TaskAction.for(task, marker(:agent_working, "pid" => "12345"))
      assert_equal "agent_running", action.key, "stage=#{stage} must short-circuit to agent_running"
      assert_equal "Agent running", action.label
      assert_nil action.command, "agent_running must emit no command"
    end
  end

  def test_error_marker_overrides_every_stage
    %w[brainstorm plan execute pr].each do |stage|
      task = fake_task(stage_name: stage, stage_index: 2)
      action = Hive::TaskAction.for(task, marker(:error, "reason" => "agent_crashed"))
      assert_equal "error", action.key
      assert_nil action.command, "error state has no runnable command"
    end
  end

  def test_execute_stale_routes_to_findings_not_develop
    # Running `hive develop slug` against a stale execute task would
    # refuse on the non-terminal marker; pointing at findings opens
    # the recovery loop instead of a verb-rejection loop.
    task = fake_task(stage_name: "execute", stage_index: 4)
    action = Hive::TaskAction.for(task, marker(:execute_stale, "max_passes" => 4))
    assert_equal "recover_execute", action.key
    assert_equal "Needs recovery", action.label
    assert_match(/\Ahive findings demo-260426-aaaa/, action.command,
                 "execute_stale must point at findings (recovery), not develop (would loop)")
  end

  # ── command emission ──────────────────────────────────────────────────

  def test_workflow_verbs_always_include_from_for_idempotency
    # Single-project, no slug collision — workflow verb commands STILL
    # carry --from <stage> so a retry after a successful advance hits
    # WRONG_STAGE (4) instead of silently advancing twice.
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_equal "hive plan demo-260426-aaaa --from 2-brainstorm", action.command
  end

  def test_workflow_verb_command_includes_project_when_multi_project
    task = fake_task(stage_name: "plan", stage_index: 3, project_root: "/proj-a")
    action = Hive::TaskAction.for(task, marker(:complete), project_name: "proj-a", project_count: 3)
    assert_equal "hive develop demo-260426-aaaa --project proj-a --from 3-plan", action.command
  end

  def test_findings_uses_stage_only_on_collision
    # Generic verbs (findings) only carry --stage when slug-collision
    # actually exists, so the common single-task command stays clean.
    task = fake_task(stage_name: "execute", stage_index: 4)
    no_collision = Hive::TaskAction.for(task, marker(:execute_waiting, "findings_count" => 2))
    assert_equal "hive findings demo-260426-aaaa", no_collision.command,
                 "findings command must NOT carry --stage absent collision"

    with_collision = Hive::TaskAction.for(task, marker(:execute_waiting, "findings_count" => 2),
                                          stage_collision: true)
    assert_equal "hive findings demo-260426-aaaa --stage 4-execute", with_collision.command
  end

  def test_command_shellescapes_slug_with_special_characters
    task = fake_task(stage_name: "brainstorm", stage_index: 2, slug: "weird slug")
    action = Hive::TaskAction.for(task, marker(:complete))
    assert_includes action.command, "weird\\ slug",
                    "shelljoin must escape whitespace"
  end

  # ── payload shape ──────────────────────────────────────────────────────

  def test_payload_has_three_keys
    task = fake_task(stage_name: "brainstorm", stage_index: 2)
    payload = Hive::TaskAction.for(task, marker(:complete)).payload
    assert_equal %w[command key label].sort, payload.keys.sort
    assert_equal "ready_to_plan", payload["key"]
  end

  # ── closed enum membership ─────────────────────────────────────────────

  def test_every_action_key_is_in_closed_enum
    Hive::TaskAction::ACTIONS.each_value do |entry|
      assert_includes Hive::Schemas::TaskActionKind::ALL, entry[:key],
                      "TaskAction emits key #{entry[:key].inspect} not in TaskActionKind::ALL"
    end
  end
end
