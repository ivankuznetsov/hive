require "test_helper"
require "hive/commands/setup_agents"

class SetupAgentsCommandTest < Minitest::Test
  class TtyInput < StringIO
    def tty? = true
  end

  class FakeProvisioner
    attr_reader :executions, :build_args

    def initialize(plan:, revised: nil, changed: false, result: nil)
      @plan = plan
      @revised = revised || plan
      @changed = changed
      @result = result
      @executions = []
    end

    def build_plan(agents: nil, skills: nil)
      @build_args = { agents: agents, skills: skills }
      @plan
    end

    def revalidate(_plan) = [ @revised, @changed ]

    def execute(plan, consent_provenance:)
      @executions << { plan: plan, consent: consent_provenance }
      @result || result_for(plan, exit_code: 0, classification: "success", consent: consent_provenance)
    end

    def noop_result(plan) = result_for(plan, exit_code: 0, classification: "no_op", consent: "not_required")
    def refusal_result(plan, provenance:) = result_for(plan, exit_code: 64, classification: "refused", consent: provenance)

    def result_for(plan, exit_code:, classification:, consent:)
      Hive::AgentSkills::ProvisioningResult.new(
        preview: plan,
        consent: { "granted" => exit_code != 64, "provenance" => consent },
        operation_results: [], final_health: plan.inspections,
        exit_code: exit_code, classification: classification
      )
    end
  end

  class InvalidProvisioner
    def build_plan(**)
      raise Hive::ConfigError, "broken effective config"
    end
  end

  def operation
    Hive::AgentSkills::Adapters::Operation.new(
      id: "claude:ce:install", agent: "claude", package_id: "compound-engineering",
      capabilities: [ "ce-brainstorm" ], kind: "plugin_install",
      argv: [ "claude", "plugin", "install", "compound-engineering@compound-engineering-plugin" ],
      files: [ "/tmp/.claude/plugins" ], depends_on: [], preconditions: {}, metadata: {}
    )
  end

  def plan(operations: [ operation ], fingerprint: "one")
    Hive::AgentSkills::ProvisioningPlan.new(
      inspections: [], operations: operations.freeze, conflicts: [],
      filters: { "agents" => [], "skills" => [] }, fingerprint: fingerprint
    )
  end

  def command(provisioner:, input:, output: StringIO.new, error: StringIO.new, **options)
    Hive::Commands::SetupAgents.new(
      config: Hive::Config::DEFAULTS,
      project_root: Dir.pwd,
      provisioner: provisioner,
      input: input,
      output: output,
      error: error,
      **options
    )
  end

  def test_interactive_preview_has_exact_command_and_prompts_once
    output = StringIO.new
    error = StringIO.new
    fake = FakeProvisioner.new(plan: plan)
    instance = command(provisioner: fake, input: TtyInput.new("y\n"), output: output, error: error)

    assert_equal 0, instance.call
    assert_includes output.string, "claude plugin install compound-engineering@compound-engineering-plugin"
    assert_includes output.string, "/tmp/.claude/plugins"
    assert_equal 1, error.string.scan(/Proceed\?/).size
    assert_equal "interactive", fake.executions.first.fetch(:consent)
  end

  def test_decline_and_non_tty_without_yes_refuse_without_execution
    [ TtyInput.new("n\n"), StringIO.new ].each do |input|
      fake = FakeProvisioner.new(plan: plan)
      instance = command(provisioner: fake, input: input)

      assert_equal 64, instance.call
      assert_empty fake.executions
    end
  end

  def test_yes_allows_non_tty_and_forwards_filters
    fake = FakeProvisioner.new(plan: plan)
    instance = command(
      provisioner: fake,
      input: StringIO.new,
      yes: true,
      agents: [ "claude" ],
      skills: [ "ce-brainstorm" ]
    )

    assert_equal 0, instance.call
    assert_equal({ agents: [ "claude" ], skills: [ "ce-brainstorm" ] }, fake.build_args)
    assert_equal "yes_flag", fake.executions.first.fetch(:consent)
  end

  def test_json_without_yes_emits_machine_readable_refusal_only
    output = StringIO.new
    error = StringIO.new
    fake = FakeProvisioner.new(plan: plan)
    instance = command(
      provisioner: fake, input: TtyInput.new("y\n"), output: output, error: error, json: true
    )

    assert_equal 64, instance.call
    payload = JSON.parse(output.string)
    assert_equal "hive-setup-agents", payload.fetch("schema")
    assert_equal "refused", payload.fetch("classification")
    assert_empty error.string
    refute_match(/Proceed/, output.string)
  end

  def test_json_yes_is_clean_and_schema_shaped
    output = StringIO.new
    fake = FakeProvisioner.new(plan: plan)
    instance = command(provisioner: fake, input: StringIO.new, output: output, json: true, yes: true)

    assert_equal 0, instance.call
    payload = JSON.parse(output.string)
    assert_equal true, payload.fetch("ok")
    assert_equal 1, payload.fetch("schema_version")
    assert_equal "yes_flag", payload.dig("consent", "provenance")
  end

  def test_revalidation_drift_prints_revised_plan_and_prompts_again
    first = plan(fingerprint: "one")
    revised = plan(operations: [ operation.with(id: "revised") ], fingerprint: "two")
    output = StringIO.new
    error = StringIO.new
    fake = FakeProvisioner.new(plan: first, revised: revised, changed: true)
    instance = command(
      provisioner: fake, input: TtyInput.new("y\ny\n"), output: output, error: error
    )

    assert_equal 0, instance.call
    assert_equal 2, error.string.scan(/Proceed\?/).size
    assert_includes output.string, "revised"
    assert_equal revised, fake.executions.first.fetch(:plan)
  end

  def test_yes_accepts_revalidated_plan_without_second_prompt
    first = plan(fingerprint: "one")
    revised = plan(operations: [ operation.with(id: "revised") ], fingerprint: "two")
    error = StringIO.new
    fake = FakeProvisioner.new(plan: first, revised: revised, changed: true)
    instance = command(provisioner: fake, input: StringIO.new, error: error, yes: true)

    assert_equal 0, instance.call
    assert_empty error.string
    assert_equal revised, fake.executions.first.fetch(:plan)
  end

  def test_noop_never_prompts
    output = StringIO.new
    error = StringIO.new
    fake = FakeProvisioner.new(plan: plan(operations: []))
    instance = command(provisioner: fake, input: TtyInput.new("y\n"), output: output, error: error)

    assert_equal 0, instance.call
    assert_empty error.string
    assert_includes output.string, "No managed agent skill changes"
  end

  def test_invalid_manifest_or_config_returns_78_before_consent
    output = StringIO.new
    error = StringIO.new
    instance = command(
      provisioner: InvalidProvisioner.new,
      input: TtyInput.new("y\n"),
      output: output,
      error: error,
      json: true,
      yes: true
    )

    assert_equal 78, instance.call
    payload = JSON.parse(output.string)
    assert_equal "invalid_config", payload.fetch("classification")
    assert_equal 78, payload.fetch("exit_code")
    assert_empty error.string
  end
end
