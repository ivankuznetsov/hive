require "test_helper"
require "hive/bot/notification_builders"
require "hive/bot/row_actions"
require "hive/bot/status_watcher"

class HiveBotRowActionsTest < Minitest::Test
  Row = Hive::Bot::StatusWatcher::Row

  def row(action: "needs_input", marker: "waiting", attrs: {}, slug: "slug-260624-abcd",
          stage: "2-brainstorm", workflow: "coding", diagnostic: nil)
    Row.new(
      project: "hive",
      slug: slug,
      stage: stage,
      workflow: workflow,
      marker: marker,
      attrs: attrs,
      folder: "/tmp/#{slug}",
      action: action,
      action_label: "Needs input",
      suggested_command: nil,
      diagnostic: diagnostic
    )
  end

  def retry_diagnostic
    { "suggested_next_action" => { "kind" => "retry", "command" => "hive review slug --json" } }
  end

  def resolve(r)
    Hive::Bot::RowActions.resolve(r)
  end

  def roles(r)
    resolve(r).actions.map(&:role)
  end

  def primary_role(r)
    resolve(r).actions.find(&:primary)&.role
  end

  def callbacks(r)
    resolve(r).actions.map(&:callback)
  end

  def test_brainstorm_waiting_answers_only_for_coding_brainstorm
    r = row(stage: "2-brainstorm", workflow: "coding")

    assert_equal [ :answer ], roles(r)
    assert_equal :answer, primary_role(r)
    assert_equal [ "answer:hive:slug-260624-abcd" ], callbacks(r)
  end

  def test_non_coding_brainstorm_named_waiting_uses_universal_run
    r = row(stage: "2-brainstorm", workflow: "blank")

    assert_equal [ :rerun ], roles(r)
    assert_equal :rerun, primary_role(r)
    assert_equal [ "rerun:hive:slug-260624-abcd:2-brainstorm:run" ], callbacks(r)
  end

  def test_plan_waiting_approves_plan_then_shows_details
    r = row(stage: "3-plan", workflow: "coding")

    assert_equal [ :approve_plan, :details ], roles(r)
    assert_equal :approve_plan, primary_role(r)
    assert_equal [
      "approve_plan:hive:slug-260624-abcd:3-plan",
      "details:hive:slug-260624-abcd:3-plan"
    ], callbacks(r)
  end

  def test_review_waiting_has_findings_triage_and_details
    r = row(marker: "review_waiting", stage: "6-review")

    assert_equal [ :findings_accept, :findings_reject, :details ], roles(r)
    assert_equal :findings_accept, primary_role(r)
    assert_equal [
      "findings:accept_all:hive:slug-260624-abcd:6-review",
      "findings:reject_all:hive:slug-260624-abcd:6-review",
      "details:hive:slug-260624-abcd:6-review"
    ], callbacks(r)
  end

  def test_review_waiting_fix_guardrail_is_details_terminal
    r = row(marker: "review_waiting", stage: "6-review", attrs: { "reason" => "fix_guardrail" })

    assert_equal [ :details ], roles(r)
    assert_equal :details, primary_role(r)
    assert Hive::Bot::RowActions.terminal_details?(r)
  end

  def test_execute_waiting_reruns_develop_then_shows_details
    r = row(marker: "execute_waiting", stage: "4-execute")

    assert_equal [ :rerun, :details ], roles(r)
    assert_equal :rerun, primary_role(r)
    assert_equal [
      "rerun:hive:slug-260624-abcd:4-execute:develop",
      "details:hive:slug-260624-abcd:4-execute"
    ], callbacks(r)
  end

  def test_finalize_waiting_runs_finalize_then_shows_details
    r = row(marker: "waiting", stage: "8-finalize")

    assert_equal [ :rerun, :details ], roles(r)
    assert_equal :rerun, primary_role(r)
    assert_equal [
      "rerun:hive:slug-260624-abcd:8-finalize:finalize",
      "details:hive:slug-260624-abcd:8-finalize"
    ], callbacks(r)
  end

  def test_generic_needs_input_runs_universal_stage_agent
    r = row(marker: "agent_waiting", stage: "2-gather", workflow: "dispatch")

    assert_equal [ :rerun ], roles(r)
    assert_equal :rerun, primary_role(r)
    assert_equal [ "rerun:hive:slug-260624-abcd:2-gather:run" ], callbacks(r)
  end

  def test_none_and_complete_needs_input_are_suppressed
    %w[none complete].each do |marker|
      resolution = resolve(row(marker: marker))

      assert resolution.suppress, "marker=#{marker} should be suppressed"
      assert_empty resolution.actions
    end
  end

  def test_ready_to_action_uses_existing_approve_callback_prefix
    r = row(action: "ready_to_finalize", marker: "complete", stage: "7-artifacts")

    assert_equal [ :approve ], roles(r)
    assert_equal :approve, primary_role(r)
    assert_equal [ "approve:finalize:hive:slug-260624-abcd:7-artifacts" ], callbacks(r)
  end

  def test_action_rejects_unknown_role_at_construction
    error = assert_raises(ArgumentError) do
      Hive::Bot::RowActions::Action.new(role: :bogus, callback: "x:y")
    end
    assert_match(/unknown action role :bogus/, error.message)
  end

  def test_resolution_rejects_unknown_kind_at_construction
    error = assert_raises(ArgumentError) do
      Hive::Bot::RowActions::Resolution.new(kind: :bogus)
    end
    assert_match(/unknown resolution kind :bogus/, error.message)
  end

  def test_resolution_primary_returns_the_single_flagged_action
    flagged = Hive::Bot::RowActions::Resolution.new(
      actions: [
        Hive::Bot::RowActions.action(:details, "details:hive:slug"),
        Hive::Bot::RowActions.action(:approve, "approve:plan:hive:slug:3-plan", primary: true)
      ],
      kind: :stage_approval
    )
    assert_equal :approve, flagged.primary.role
  end

  def test_resolution_requires_exactly_one_primary_when_actions_present
    # No fallback to actions.first: a resolver path forgetting `primary: true`
    # (or flagging two) is a construction bug, not a silently-tolerated state.
    zero = assert_raises(ArgumentError) do
      Hive::Bot::RowActions::Resolution.new(
        actions: [ Hive::Bot::RowActions.action(:details, "details:hive:slug") ],
        kind: :recovery
      )
    end
    assert_match(/exactly one primary/, zero.message)

    two = assert_raises(ArgumentError) do
      Hive::Bot::RowActions::Resolution.new(
        actions: [
          Hive::Bot::RowActions.action(:details, "details:hive:slug", primary: true),
          Hive::Bot::RowActions.action(:approve, "approve:plan:hive:slug:3-plan", primary: true)
        ],
        kind: :stage_approval
      )
    end
    assert_match(/exactly one primary/, two.message)
  end

  def test_empty_resolution_has_no_primary
    empty = Hive::Bot::RowActions::Resolution.new(kind: :none)
    assert_nil empty.primary
    assert_empty empty.actions
  end

  def test_rerun_action_requires_a_verb
    error = assert_raises(ArgumentError) do
      Hive::Bot::RowActions.action(:rerun, "rerun:hive:slug:4-execute:develop")
    end
    assert_match(/:rerun requires a verb/, error.message)
  end

  def test_action_requires_a_callback
    error = assert_raises(ArgumentError) do
      Hive::Bot::RowActions.action(:details, "")
    end
    assert_match(/requires a callback/, error.message)
  end

  def test_recovery_uses_existing_autofix_and_details_callbacks
    retryable = row(action: "recover_review", marker: "review_error", stage: "6-review",
                    attrs: { "pass" => "2" }, diagnostic: retry_diagnostic)
    manual = row(action: "recover_execute", marker: "execute_stale", stage: "4-execute")

    assert_equal [ :autofix ], roles(retryable)
    assert_equal [ "autofix:hive:slug-260624-abcd:6-review:review_error:pass=2" ],
                 callbacks(retryable)
    assert_equal [ :details ], roles(manual)
    assert_equal [ "details:hive:slug-260624-abcd:4-execute" ], callbacks(manual)
    assert Hive::Bot::RowActions.terminal_details?(manual)
  end
end
