require "test_helper"
require "hive/conditions/gate_evaluator"

class ConditionsGateEvaluatorTest < Minitest::Test
  def test_satisfied_requirements_and_inactive_inhibitor_are_eligible
    result = evaluate(
      "AgentHealthy" => fact("AgentHealthy", "satisfied"),
      "ChangesPresent" => fact("ChangesPresent", "satisfied"),
      "AwaitingHuman" => fact("AwaitingHuman", "unsatisfied")
    )

    assert result.eligible?
    assert_empty result.diagnostics
  end

  def test_pending_requests_reconciliation_while_negative_and_unverifiable_fail_distinctly
    pending = evaluate(
      "AgentHealthy" => fact("AgentHealthy", "pending"),
      "ChangesPresent" => fact("ChangesPresent", "satisfied"),
      "AwaitingHuman" => fact("AwaitingHuman", "unsatisfied")
    )
    assert pending.reconcile_required?
    assert_equal "unknown/reconcile_required", pending.diagnostics.first.fetch("code")

    %w[unsatisfied unverifiable].each do |state|
      blocked = evaluate(
        "AgentHealthy" => fact("AgentHealthy", "satisfied"),
        "ChangesPresent" => fact("ChangesPresent", state),
        "AwaitingHuman" => fact("AwaitingHuman", "unsatisfied")
      )
      assert_equal :blocked, blocked.status
      assert_equal "condition_#{state}", blocked.diagnostics.first.fetch("code")
    end
  end

  def test_active_wait_blocks_but_historical_or_answered_wait_does_not
    active = evaluate(
      "AgentHealthy" => fact("AgentHealthy", "satisfied"),
      "ChangesPresent" => fact("ChangesPresent", "satisfied"),
      "AwaitingHuman" => fact("AwaitingHuman", "satisfied", reason: "no_worktree_changes")
    )
    assert_equal :blocked, active.status
    assert_equal "inhibitor", active.diagnostics.first.fetch("role")

    answered = evaluate(
      "AgentHealthy" => fact("AgentHealthy", "satisfied"),
      "ChangesPresent" => fact("ChangesPresent", "satisfied"),
      "AwaitingHuman" => fact("AwaitingHuman", "unsatisfied")
    )
    assert answered.eligible?
  end

  def test_research_waiver_requires_declared_policy_and_evidence
    rule = Hive::Conditions::Policy.rule_from_descriptor({
      "transition" => "execute_to_open_pr",
      "required" => %w[AgentHealthy ChangesPresent],
      "inhibitors" => [ "AwaitingHuman" ],
      "options" => { "no_commit_success" => true }
    })
    projection = projection(
      "AgentHealthy" => fact("AgentHealthy", "satisfied"),
      "ChangesPresent" => fact("ChangesPresent", "unsatisfied", reason: "research_no_commit"),
      "AwaitingHuman" => fact("AwaitingHuman", "unsatisfied")
    )

    denied = Hive::Conditions::GateEvaluator.new(projection: projection, rule: rule)
                                               .evaluate(research: true, research_evidence: false)
    assert_equal :blocked, denied.status
    allowed = Hive::Conditions::GateEvaluator.new(projection: projection, rule: rule)
                                                .evaluate(research: true, research_evidence: true)
    assert allowed.eligible?
    assert_equal "no_commit_success", allowed.waivers.first.fetch("reason")
  end

  def test_terminal_agent_health_is_informational
    result = evaluate(
      "AgentHealthy" => fact(
        "AgentHealthy", "unsatisfied", payload: { "informational_after_terminal" => true }
      ),
      "ChangesPresent" => fact("ChangesPresent", "satisfied"),
      "AwaitingHuman" => fact("AwaitingHuman", "unsatisfied")
    )
    assert result.eligible?
  end

  private

  def evaluate(facts)
    Hive::Conditions::GateEvaluator.new(
      projection: projection(facts),
      rule: Hive::Conditions::Policy.default.rule_for("execute_to_open_pr")
    ).evaluate
  end

  def projection(facts)
    { "conditions" => { "current" => facts.values, "history" => [] } }
  end

  def fact(name, state, reason: "observed", payload: {})
    { "condition" => name, "state" => state, "reason" => reason, "payload" => payload }
  end
end
