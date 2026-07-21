require "test_helper"
require "hive/digest"
require "hive/agent_skills/provisioner"

class AgentSkillsProvisionerTest < Minitest::Test
  class SequenceInspector
    attr_reader :calls

    def initialize(*sequences)
      @sequences = sequences
      @last = sequences.last
      @calls = []
    end

    def inspect(agents: nil, skills: nil)
      @calls << { agents: agents, skills: skills }
      @sequences.empty? ? @last : @sequences.shift
    end
  end

  class FakeAdapter
    attr_reader :executed

    def initialize(plan:, outcomes: {})
      @plan = plan
      @outcomes = outcomes
      @executed = []
    end

    def plan(_rows) = @plan

    def execute(operation)
      @executed << operation.id
      @outcomes.fetch(operation.id) do
        Hive::AgentSkills::Adapters::Outcome.new(
          operation_id: operation.id, agent: operation.agent, package_id: operation.package_id,
          status: "succeeded", message: "ok", exit_status: 0, changed_files: operation.files
        )
      end
    end
  end

  class FakeRegistry
    def initialize(adapters) = @adapters = adapters
    def fetch(agent) = @adapters.fetch(agent)
  end

  def target(agent:, capability:, managed: true)
    Hive::AgentSkills::Target.new(
      surfaces: [ "test" ], kind: "stage", agent: agent,
      configured_skill: capability, invocation: "/#{capability}",
      capability_id: managed ? capability : nil,
      package_id: managed ? "compound-engineering" : nil,
      managed: managed
    )
  end

  def row(agent: "claude", capability: "ce-brainstorm", health: "missing", managed: true)
    Hive::AgentSkills::Inspection.new(
      target: target(agent: agent, capability: capability, managed: managed),
      expected: {}, native: { "available" => health != "unavailable", "bin" => "/fake/#{agent}" },
      resolution: {}, health: health,
      severity: %w[healthy unavailable].include?(health) ? "warning" : "error",
      explanation: health, remediation: managed ? "repair" : "manual"
    )
  end

  def operation(id:, agent: "claude", depends_on: [])
    Hive::AgentSkills::Adapters::Operation.new(
      id: id, agent: agent, package_id: "compound-engineering",
      capabilities: [ "ce-brainstorm" ], kind: "plugin_install",
      argv: [ "/fake/#{agent}", "install", id ], files: [],
      depends_on: depends_on, preconditions: {}, metadata: {}
    )
  end

  def adapter_plan(agent:, operations:, conflicts: [])
    Hive::AgentSkills::Adapters::AdapterPlan.new(
      agent: agent, operations: operations.freeze, conflicts: conflicts.freeze
    )
  end

  def provisioner(inspector:, adapters: {})
    Hive::AgentSkills::Provisioner.new(
      config: Hive::Config::DEFAULTS,
      project_root: Dir.pwd,
      inspector: inspector,
      adapters: FakeRegistry.new(adapters)
    )
  end

  def test_build_plan_contains_exact_immutable_adapter_operations
    inspection = row
    op = operation(id: "claude:ce:install")
    adapter = FakeAdapter.new(plan: adapter_plan(agent: "claude", operations: [ op ]))
    instance = provisioner(inspector: SequenceInspector.new([ inspection ]), adapters: { "claude" => adapter })

    plan = instance.build_plan(agents: [ "claude" ], skills: [ "ce-brainstorm" ])

    assert_equal [ op ], plan.operations
    assert plan.frozen?
    assert plan.operations.frozen?
    assert_equal [ "/fake/claude", "install", "claude:ce:install" ], plan.to_h.dig("operations", 0, "argv")
  end

  def test_revalidate_detects_preview_drift
    op = operation(id: "one")
    adapter = FakeAdapter.new(plan: adapter_plan(agent: "claude", operations: [ op ]))
    inspector = SequenceInspector.new([ row ], [ row(health: "healthy") ])
    instance = provisioner(inspector: inspector, adapters: { "claude" => adapter })
    preview = instance.build_plan

    revised, changed = instance.revalidate(preview)

    assert changed
    assert_empty revised.operations
    refute_equal preview.fingerprint, revised.fingerprint
  end

  def test_partial_failure_continues_independent_agent_and_skips_only_dependency
    claude_op = operation(id: "claude-fail")
    dependent = operation(id: "claude-dependent", depends_on: [ claude_op.id ])
    pi_op = operation(id: "pi-ok", agent: "pi")
    failed = Hive::AgentSkills::Adapters::Outcome.new(
      operation_id: claude_op.id, agent: "claude", package_id: "compound-engineering",
      status: "failed", message: "offline", exit_status: 1, changed_files: []
    )
    claude = FakeAdapter.new(
      plan: adapter_plan(agent: "claude", operations: [ claude_op, dependent ]),
      outcomes: { claude_op.id => failed }
    )
    pi = FakeAdapter.new(plan: adapter_plan(agent: "pi", operations: [ pi_op ]))
    initial = [ row(agent: "claude"), row(agent: "pi") ]
    final = [ row(agent: "claude"), row(agent: "pi", health: "healthy") ]
    instance = provisioner(
      inspector: SequenceInspector.new(initial, final),
      adapters: { "claude" => claude, "pi" => pi }
    )
    plan = instance.build_plan

    result = instance.execute(plan, consent_provenance: "yes_flag")

    assert_equal %w[failed skipped succeeded], result.operation_results.map(&:status)
    assert_equal [ pi_op.id ], pi.executed
    assert_equal 1, result.exit_code
    assert_equal "residual_failure", result.classification
    assert_equal "residual_failure", result.to_h.fetch("classification")
  end

  def test_unavailable_only_and_already_healthy_plans_are_successful_noops
    [ [ row(health: "unavailable") ], [ row(health: "healthy") ] ].each do |rows|
      instance = provisioner(inspector: SequenceInspector.new(rows), adapters: {})
      result = instance.noop_result(instance.build_plan)

      assert_equal 0, result.exit_code
      assert_equal "no_op", result.classification
      assert_empty result.operation_results
    end
  end

  def test_actionable_conflict_without_operations_is_a_residual_failure
    instance = provisioner(inspector: SequenceInspector.new([ row(health: "conflicting") ]), adapters: {})

    result = instance.noop_result(instance.build_plan)

    assert_equal 1, result.exit_code
    assert_equal "residual_failure", result.classification
  end

  def test_refusal_result_uses_usage_exit_code_without_execution
    op = operation(id: "one")
    adapter = FakeAdapter.new(plan: adapter_plan(agent: "claude", operations: [ op ]))
    instance = provisioner(inspector: SequenceInspector.new([ row ]), adapters: { "claude" => adapter })

    result = instance.refusal_result(instance.build_plan, provenance: "non_tty")

    assert_equal 64, result.exit_code
    assert_equal "refused", result.classification
    assert_empty adapter.executed
  end

  def test_unattended_consent_refusal_validates_scope_without_inspection
    inspector = SequenceInspector.new([ row ])
    instance = provisioner(inspector: inspector, adapters: {})

    result = instance.consent_required_result(
      agents: [ "claude" ], skills: [ "hive" ], provenance: "json_requires_yes"
    )

    assert_equal 64, result.exit_code
    assert_equal "refused", result.classification
    assert_equal "json_requires_yes", result.consent.fetch("provenance")
    assert_equal({ "agents" => [ "claude" ], "skills" => [ "hive" ] }, result.preview.filters)
    assert_match(/\A[0-9a-f]{64}\z/, result.preview.fingerprint)
    assert_empty result.preview.inspections
    assert_empty result.preview.operations
    assert_empty inspector.calls
  end

  def test_unattended_consent_refusal_still_rejects_invalid_filters
    instance = provisioner(inspector: SequenceInspector.new([ row ]), adapters: {})

    assert_raises(Hive::ConfigError) do
      instance.consent_required_result(agents: [ "ghost" ], provenance: "non_tty")
    end
    assert_raises(Hive::ConfigError) do
      instance.consent_required_result(skills: [ "ghost-skill" ], provenance: "non_tty")
    end
  end

  def test_filtered_unmanaged_skill_is_rejected_before_adapter_planning
    instance = provisioner(
      inspector: SequenceInspector.new([ row(capability: "private", managed: false) ]),
      adapters: {}
    )

    error = assert_raises(Hive::ConfigError) do
      instance.build_plan(skills: [ "private" ])
    end

    assert_match(/unmanaged custom skill/, error.message)
  end

  def test_unattended_refusal_rejects_a_filtered_unmanaged_skill_without_inspection
    cfg = Marshal.load(Marshal.dump(Hive::Config::DEFAULTS))
    cfg["review"]["reviewers"] << {
      "name" => "private", "kind" => "agent", "agent" => "claude", "skill" => "private-review"
    }
    inspector = SequenceInspector.new([ row ])
    instance = Hive::AgentSkills::Provisioner.new(
      config: cfg, project_root: Dir.pwd, inspector: inspector, adapters: FakeRegistry.new({})
    )

    error = assert_raises(Hive::ConfigError) do
      instance.consent_required_result(skills: [ "private-review" ], provenance: "non_tty")
    end

    assert_match(/unmanaged custom skill.*private-review/, error.message)
    assert_empty inspector.calls
  end
end
