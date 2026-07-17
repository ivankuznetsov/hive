require "test_helper"
require "hive/conditions/policy"

class ConditionsPolicyTest < Minitest::Test
  def test_default_policy_maps_full_vocabulary_and_authoritative_transitions
    policy = Hive::Conditions::Policy.default
    execute = policy.rule_for("execute_to_open_pr")

    assert_equal %w[AgentHealthy ChangesPresent], execute.required
    assert_equal [ "AwaitingHuman" ], execute.inhibitors
    assert execute.authoritative_capable
    refute policy.rule_for("open_pr_to_review").authoritative_capable
    refute policy.rule_for("review_active").authoritative_capable
    refute policy.rule_for("artifacts_to_finalize").authoritative_capable
    finalize = policy.rule_for("finalize_to_archive")
    assert_equal [ "ArchiveReady" ], finalize.required
    assert finalize.authoritative_capable
  end

  def test_descriptor_rule_accepts_registered_semantics_and_research_option
    rule = Hive::Conditions::Policy.rule_from_descriptor({
      "version" => 1,
      "transition" => "research_complete",
      "required" => [ "ChangesPresent" ],
      "inhibitors" => [ "AwaitingHuman" ],
      "options" => { "no_commit_success" => true }
    })

    assert_equal "research_complete", rule.transition
    assert rule.options.fetch("no_commit_success")
    refute rule.authoritative_capable
  end

  def test_policy_rejects_unknown_duplicate_conflicting_or_wrong_role_conditions
    invalid = [
      [],
      {},
      { "transition" => "x", "required" => [ "Unknown" ] },
      { "transition" => "x", "required" => %w[ChangesPresent ChangesPresent] },
      { "transition" => "x", "required" => [ "AwaitingHuman" ] },
      { "transition" => "x", "inhibitors" => [ "ChangesPresent" ] },
      { "transition" => "x", "required" => [ "ChangesPresent" ],
        "inhibitors" => [ "ChangesPresent" ] },
      { "transition" => "x", "options" => { "ad_hoc_semantics" => true } }
    ]
    invalid.each do |descriptor|
      assert_raises(Hive::Conditions::InvalidPolicy) do
        Hive::Conditions::Policy.rule_from_descriptor(descriptor)
      end
    end

    assert_raises(Hive::Conditions::InvalidPolicy) do
      Hive::Conditions::Policy.default.rule_for("unknown_transition")
    end
  end
end
