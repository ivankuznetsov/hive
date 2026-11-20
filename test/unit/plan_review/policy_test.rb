require "test_helper"
require "hive/plan_review/policy"

class PlanReviewPolicyTest < Minitest::Test
  FakeSignals = Data.define(:skip_eligible?, :mandatory_reasons, :evidence, :plan_path) do
    def to_h
      {
        "skip_eligible" => skip_eligible?,
        "mandatory_reasons" => mandatory_reasons,
        "evidence" => evidence,
        "plan_path" => plan_path
      }
    end
  end
  FakeReview = Data.define(:resolved, :routes) do
    def execution_allowed? = resolved

    def [](key) = key.to_s == "routes" ? routes : nil
  end

  def test_non_coding_workflows_are_not_applicable
    result = Hive::PlanReview::Policy.evaluate(
      workflow_id: "research", signals: signals(skip: true), config: config
    )

    refute result.applicable?
    assert_nil result.computed_level
    assert_nil result.effective_level
  end

  def test_explicitly_disabled_coding_review_is_not_applicable
    result = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false),
      config: config.merge("enabled" => false)
    )

    refute result.applicable?
    assert_nil result.computed_level
    assert_nil result.effective_level
  end

  def test_skip_requires_affirmative_signals_and_uncertainty_defaults_standard
    skip = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: true), config: config
    )
    ordinary = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false), config: config
    )

    assert_equal "skip", skip.computed_level
    assert_equal "skip", skip.effective_level
    assert_equal "standard", ordinary.computed_level
    assert_equal "standard", ordinary.effective_level
  end

  def test_any_mandatory_reason_requires_mandatory_review
    result = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding",
      signals: signals(
        skip: true,
        mandatory: [ { "category" => "auth_secrets_permissions", "evidence" => "auth" } ]
      ),
      config: config
    )

    assert_equal "mandatory", result.computed_level
    assert_equal "mandatory", result.effective_level
    assert_equal [ "auth_secrets_permissions" ], result.matched_reasons.map { |r| r["category"] }
  end

  def test_project_workflow_and_run_levels_only_raise
    project_raise = config.merge("minimum_level" => "standard")
    result = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding",
      signals: signals(skip: true),
      config: project_raise,
      run_level: "mandatory"
    )

    assert_equal "skip", result.computed_level
    assert_equal "mandatory", result.effective_level
    assert_equal "mandatory", result.level_sources.fetch("run")

    error = assert_raises(Hive::ConfigError) do
      Hive::PlanReview::Policy.evaluate(
        workflow_id: "coding",
        signals: signals(skip: false),
        config: config,
        run_level: "skip"
      )
    end
    assert_match(/run review level cannot lower/i, error.message)
  end

  def test_fingerprint_is_stable_for_equivalent_inputs_and_changes_materially
    a = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false), config: config
    )
    b = Hive::PlanReview::Policy.evaluate(
      workflow_id: :coding, signals: signals(skip: false), config: config.dup
    )
    c = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding",
      signals: signals(skip: false, evidence: { "declared_files" => [ "lib/changed.rb" ] }),
      config: config
    )

    assert_equal a.policy_fingerprint, b.policy_fingerprint
    refute_equal a.policy_fingerprint, c.policy_fingerprint
    assert_match(/\A[0-9a-f]{64}\z/, a.policy_fingerprint)
  end

  def test_fingerprint_does_not_change_when_the_task_folder_moves_between_stages
    plan = signals(skip: false, plan_path: "/tmp/project/.hive-state/stages/3-plan/demo/plan.md")
    moved = signals(skip: false, plan_path: "/tmp/project/.hive-state/stages/4-execute/demo/plan.md")

    first = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: plan, config: config
    )
    second = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: moved, config: config
    )

    assert_equal first.policy_fingerprint, second.policy_fingerprint
  end

  def test_operational_attempt_tuning_does_not_rekey_a_review
    first = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false),
      config: config.merge("attempts" => { "timeout_sec" => 900, "max_transient" => 1 })
    )
    second = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false),
      config: config.merge("attempts" => { "timeout_sec" => 1800, "max_transient" => 4 })
    )

    assert_equal first.policy_fingerprint, second.policy_fingerprint
  end

  def test_planner_revision_fallback_does_not_discard_the_current_review
    review_route = {
      "agent" => "codex", "model" => "gpt-5.6-sol", "family" => "openai",
      "effort" => "high", "route" => "native_codex"
    }
    routes = { "primary" => review_route }
    recovered = routes.merge(
      "planner_revision_fallback" => review_route.merge("route" => "recovery_codex")
    )
    first = config.merge("routes" => routes)
    second = config.merge("routes" => recovered)

    fingerprint = ->(cfg) do
      Hive::PlanReview::Policy.evaluate(
        workflow_id: "coding", signals: signals(skip: false), config: cfg
      ).policy_fingerprint
    end

    assert_equal fingerprint.call(first), fingerprint.call(second)
    assert_equal Hive::PlanReview::Policy.configuration_fingerprint(first),
                 Hive::PlanReview::Policy.configuration_fingerprint(second)
  end

  def test_reviewer_or_adapter_change_rekeys_a_review
    base = config.merge(
      "adapter" => "ce_doc_review",
      "reviewers" => { "primary" => { "agent" => "pi" } }
    )
    reviewer_changed = base.merge(
      "reviewers" => { "primary" => { "agent" => "codex" } }
    )
    adapter_changed = base.merge("adapter" => "codex_review")

    first = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false), config: base
    )
    second = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false), config: reviewer_changed
    )
    third = Hive::PlanReview::Policy.evaluate(
      workflow_id: "coding", signals: signals(skip: false), config: adapter_changed
    )

    refute_equal first.policy_fingerprint, second.policy_fingerprint
    refute_equal first.policy_fingerprint, third.policy_fingerprint
  end

  def test_effective_review_model_routing_rekeys_without_tracking_unrelated_stages
    base = {
      "plan_review" => config,
      "models" => {
        "plan_review" => { "model" => "openrouter/stealth/ox-alpha" },
        "plan_review_adversarial" => { "model" => "gpt-5.6-sol", "effort" => "high" },
        "execute" => { "model" => "gpt-5.6-terra" }
      }
    }
    changed_reviewer = Marshal.load(Marshal.dump(base))
    changed_reviewer.dig("models", "plan_review_adversarial")["effort"] = "xhigh"
    changed_execute = Marshal.load(Marshal.dump(base))
    changed_execute.dig("models", "execute")["model"] = "gpt-5.6-sol"

    fingerprint = ->(cfg) do
      Hive::PlanReview::Policy.evaluate(
        workflow_id: "coding", signals: signals(skip: false), config: cfg
      ).policy_fingerprint
    end

    refute_equal fingerprint.call(base), fingerprint.call(changed_reviewer)
    assert_equal fingerprint.call(base), fingerprint.call(changed_execute)
    refute_equal Hive::PlanReview::Policy.configuration_fingerprint(base),
                 Hive::PlanReview::Policy.configuration_fingerprint(changed_reviewer)
  end

  def test_non_integer_classifier_version_is_a_config_error
    error = assert_raises(Hive::ConfigError) do
      Hive::PlanReview::Policy.evaluate(
        workflow_id: "coding", signals: signals(skip: false),
        config: config.merge("classifier_version" => "one")
      )
    end

    assert_match(/classifier_version must be an Integer/, error.message)
  end

  def test_fingerprint_includes_the_reviewer_adapter_contract_version
    affecting = Hive::PlanReview::Policy.policy_affecting_config(config)

    assert_equal Hive::PlanReview::ADAPTER_CONTRACT_VERSION,
                 affecting.fetch("adapter_contract_version")
  end

  def test_reviewer_routing_is_who_reviews_without_the_planner_fallback
    full = routed_config
    full["plan_review"]["routes"]["planner_revision_fallback"] = route("codex", "gpt-5.6-sol", "openai")

    routing = Hive::PlanReview::Policy.reviewer_routing(full)

    assert_equal %w[model_routing reviewers routes], routing.keys.sort
    assert_equal full.dig("plan_review", "reviewers"), routing.fetch("reviewers")
    assert_equal %w[adversarial fallbacks primary verification], routing.fetch("routes").keys.sort
    assert_equal({ "plan_review" => { "effort" => "xhigh" } }, routing.fetch("model_routing"))
  end

  # Restoring a review's own reviewer routing leaves only verdict-relevant
  # drift: rerouting every reviewer (and its model routing) reproduces the
  # recorded fingerprint, while any change to what a review must establish
  # still does not.
  def test_restoring_recorded_reviewer_routing_isolates_verdict_relevant_drift
    policy = Hive::PlanReview::Policy
    base = routed_config
    recorded = policy.configuration_fingerprint(base)
    routing = policy.reviewer_routing(base)
    rerouted = reroute(base)
    refute_equal recorded, policy.configuration_fingerprint(rerouted)
    assert_equal recorded, policy.configuration_fingerprint(policy.with_reviewer_routing(rerouted, routing))

    verdict_changes = {
      "minimum_level" => ->(cfg) { cfg["plan_review"]["minimum_level"] = "mandatory" },
      "coding minimum_level" => ->(cfg) { cfg["plan_review"]["coding"]["minimum_level"] = "standard" },
      "protected_paths" => ->(cfg) { cfg["plan_review"]["protected_paths"] << "app/models/**" },
      "coverage" => ->(cfg) { cfg["plan_review"]["coverage"]["optional"] << "security" },
      "classifier_version" => ->(cfg) { cfg["plan_review"]["classifier_version"] = 2 },
      "adapter" => ->(cfg) { cfg["plan_review"]["adapter"] = "replacement_review" }
    }
    verdict_changes.each do |label, change|
      changed = Marshal.load(Marshal.dump(rerouted))
      change.call(changed)
      refute_equal recorded,
                   policy.configuration_fingerprint(policy.with_reviewer_routing(changed, routing)),
                   "#{label} must still stale a resolved review"
    end
    assert_equal Hive::PlanReview::ADAPTER_CONTRACT_VERSION,
                 policy.policy_affecting_config(
                   policy.with_reviewer_routing(rerouted, routing)["plan_review"]
                 ).fetch("adapter_contract_version")
  end

  def test_configuration_current_ignores_reviewer_routing_only_for_resolved_reviews
    policy = Hive::PlanReview::Policy
    base = routed_config
    artifact = {
      "configuration_fingerprint" => policy.configuration_fingerprint(base),
      "reviewer_routing" => policy.reviewer_routing(base)
    }
    rerouted = reroute(base)
    raised = Marshal.load(Marshal.dump(rerouted))
    raised["plan_review"]["minimum_level"] = "mandatory"

    assert policy.configuration_current?(rerouted, artifact:, record: review(resolved: true))
    refute policy.configuration_current?(raised, artifact:, record: review(resolved: true))
    refute policy.configuration_current?(rerouted, artifact:, record: review(resolved: false))
    assert policy.configuration_current?(base, artifact:, record: review(resolved: false))
  end

  # Policy artifacts from before `reviewer_routing` was recorded: the routing
  # is rebuilt from the review's own route receipts and trusted only when it
  # reproduces the recorded digest.
  def test_legacy_resolved_review_rebuilds_its_routing_from_route_receipts
    policy = Hive::PlanReview::Policy
    base = routed_config
    legacy = { "configuration_fingerprint" => policy.configuration_fingerprint(base) }
    receipts = %w[primary adversarial verification].map do |role|
      { "role" => role, "requested" => receipt_route(base.dig("plan_review", "routes", role)) }
    end
    rerouted = reroute(base, model_routing: false)
    raised = Marshal.load(Marshal.dump(rerouted))
    raised["plan_review"]["protected_paths"] << "app/models/**"
    resolved = review(resolved: true, routes: receipts)

    # Upgrading Hive alone never stales a legacy review.
    assert policy.configuration_current?(base, artifact: legacy, record: review(resolved: true))
    assert policy.configuration_current?(rerouted, artifact: legacy, record: resolved)
    refute policy.configuration_current?(raised, artifact: legacy, record: resolved)
    refute policy.configuration_current?(rerouted, artifact: legacy, record: review(resolved: false, routes: receipts))
    # What the receipts cannot show fails closed: a rerouted role the review
    # never ran, or a review model routing change.
    refute policy.configuration_current?(
      rerouted, artifact: legacy, record: review(resolved: true, routes: receipts.first(2))
    )
    refute policy.configuration_current?(reroute(base), artifact: legacy, record: resolved)
  end

  private

  def review(resolved:, routes: [])
    FakeReview.new(resolved:, routes:)
  end

  def route(agent, model, family, effort: "high", route: "native_#{agent}")
    { "agent" => agent, "model" => model, "family" => family, "effort" => effort, "route" => route }
  end

  def receipt_route(row)
    {
      "provider" => row.fetch("agent"), "model" => row.fetch("model"),
      "family" => row.fetch("family"), "effort" => row.fetch("effort"), "route" => row.fetch("route")
    }
  end

  def routed_config
    {
      "plan_review" => config.merge(
        "coverage" => { "required" => %w[whole_document adversarial], "optional" => [] },
        "adapter" => "ce_doc_review",
        "reviewers" => {
          "primary" => "plan_review", "adversarial" => "plan_review_adversarial",
          "verification" => "plan_review_verification"
        },
        "routes" => {
          "primary" => route("muse", "muse-wonder-full-1.0", "meta", effort: "xhigh"),
          "adversarial" => route("codex", "gpt-6-astra", "openai"),
          "verification" => route("muse", "muse-wonder-full-1.0", "meta", effort: "xhigh"),
          "fallbacks" => []
        }
      ),
      "models" => {
        "plan_review" => { "effort" => "xhigh" },
        "execute" => { "model" => "gpt-5.6-terra" }
      }
    }
  end

  # The todero reroute of 2026-11-20 (Muse and Codex out of quota), by default
  # with a review model routing change too.
  def reroute(base, model_routing: true)
    rerouted = Marshal.load(Marshal.dump(base))
    routes = rerouted["plan_review"]["routes"]
    grok = route("grok", "grok-4.7", "grok", effort: "xhigh", route: "native_grok_build")
    routes["primary"] = grok
    routes["verification"] = grok
    routes["adversarial"] = route("claude", "claude-opus-5-5", "anthropic", effort: "xhigh")
    rerouted["models"]["plan_review_verification"] = { "effort" => "high" } if model_routing
    rerouted
  end

  def config
    {
      "enabled" => true,
      "minimum_level" => "skip",
      "coding" => { "minimum_level" => "skip" },
      "classifier_version" => 1,
      "skip" => { "max_files" => 5, "max_bytes" => 262_144 },
      "protected_paths" => []
    }
  end

  def signals(skip:, mandatory: [], evidence: {}, plan_path: "/tmp/plan.md")
    FakeSignals.new(
      skip_eligible?: skip,
      mandatory_reasons: mandatory,
      evidence: { "declared_files" => [ "lib/example.rb" ] }.merge(evidence),
      plan_path:
    )
  end
end
