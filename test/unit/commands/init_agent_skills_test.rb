require "test_helper"
require "hive/commands/init"

class InitAgentSkillsTest < Minitest::Test
  include HiveTestHelper

  class TtyInput < StringIO
    def tty? = true
  end

  class FixedInspector
    def initialize(rows) = @rows = rows
    def inspect = @rows
  end

  class FakeSetup
    attr_reader :calls
    def initialize(exit_code) = (@exit_code = exit_code; @calls = 0)
    def call = (@calls += 1; @exit_code)
  end

  def inspection(health: "missing", capability: "ce-brainstorm")
    target = Hive::AgentSkills::Target.new(
      surfaces: [ "brainstorm" ], kind: "stage", agent: "claude",
      configured_skill: "/#{capability}", invocation: "/#{capability}",
      capability_id: capability, package_id: "compound-engineering", managed: true
    )
    Hive::AgentSkills::Inspection.new(
      target: target, expected: {}, native: { "available" => health != "unavailable" },
      resolution: {}, health: health,
      severity: health == "unavailable" ? "warning" : "error",
      explanation: "#{capability} is #{health}",
      remediation: "hive setup-agents --agent claude --skill #{capability}"
    )
  end

  def init_with(rows:, input:, json: false, setup: FakeSetup.new(0), output: StringIO.new, error: StringIO.new, &capture)
    factory = lambda do |**kwargs|
      capture&.call(kwargs)
      setup
    end
    command = Hive::Commands::Init.new(
      Dir.pwd,
      json: json,
      provisioning_input: input,
      provisioning_output: output,
      provisioning_error: error,
      preflight_inspector: FixedInspector.new(rows),
      setup_agents_factory: factory
    )
    [ command, setup, output, error ]
  end

  def test_interactive_acceptance_delegates_once_with_recorded_consent
    captured = nil
    command, setup, output, error = init_with(
      rows: [ inspection ], input: TtyInput.new("y\n")
    ) { |kwargs| captured = kwargs }

    command.send(:run_init_preflight!)

    assert_equal 1, setup.calls
    assert_equal "init_interactive", captured.fetch(:consent_provenance)
    assert_same output, captured.fetch(:output)
    assert_same error, captured.fetch(:error)
    assert_equal 1, error.string.scan(/Provision unresolved/).size
  end

  def test_decline_reports_standalone_remediation_without_setup
    command, setup, _output, error = init_with(
      rows: [ inspection ], input: TtyInput.new("n\n")
    )

    command.send(:run_init_preflight!)

    assert_equal 0, setup.calls
    assert_includes error.string, "hive setup-agents --agent claude --skill ce-brainstorm"
  end

  def test_healthy_and_unavailable_only_rows_do_not_offer
    [ [ inspection(health: "healthy") ], [ inspection(health: "unavailable") ] ].each do |rows|
      command, setup, _output, error = init_with(rows: rows, input: TtyInput.new("y\n"))

      command.send(:run_init_preflight!)

      assert_equal 0, setup.calls
      refute_includes error.string, "Provision unresolved"
    end
  end

  def test_non_tty_and_json_never_mutate
    [ [ StringIO.new, false ], [ TtyInput.new("y\n"), true ] ].each do |input, json|
      command, setup, _output, error = init_with(rows: [ inspection ], input: input, json: json)

      command.send(:run_init_preflight!)

      assert_equal 0, setup.calls
      assert_includes error.string, "run `hive setup-agents`"
      refute_includes error.string, "Provision unresolved"
    end
  end

  def test_partial_setup_failure_keeps_init_non_fatal_and_prints_rerun
    command, setup, _output, error = init_with(
      rows: [ inspection ], input: TtyInput.new("yes\n"), setup: FakeSetup.new(1)
    )

    assert_nil command.send(:run_init_preflight!)
    assert_equal 1, setup.calls
    assert_includes error.string, "project remains initialized"
    assert_includes error.string, "Re-run `hive setup-agents`"
  end

  def test_default_setup_factory_builds_setup_agents_command
    command = Hive::Commands::Init.new(Dir.pwd)
    fake = FakeSetup.new(0)
    captured = nil
    replacement = lambda do |**kwargs|
      captured = kwargs
      fake
    end
    with_replaced_singleton_method(Hive::Commands::SetupAgents, :new, replacement) do
      built = command.instance_variable_get(:@setup_agents_factory).call(
        config: Hive::Config::DEFAULTS, project_root: Dir.pwd
      )
      assert_same fake, built
    end
    assert_equal Dir.pwd, captured.fetch(:project_root)
  end

  def test_setup_orchestrator_can_disable_only_the_post_init_skill_preflight
    command = Hive::Commands::Init.new(Dir.pwd, agent_skill_preflight: false)
    assert_equal false, command.instance_variable_get(:@agent_skill_preflight)

    assert_raises(ArgumentError) do
      Hive::Commands::Init.new(Dir.pwd, agent_skill_preflight: :sometimes)
    end
  end

  def test_closed_tty_probe_falls_back_to_warnings
    input = Object.new
    input.define_singleton_method(:tty?) { raise IOError, "closed" }
    command, setup, _output, error = init_with(rows: [ inspection ], input: input)

    command.send(:run_init_preflight!)

    assert_equal 0, setup.calls
    assert_includes error.string, "run `hive setup-agents`"
  end

  def test_epipe_while_printing_preflight_warnings_is_ignored
    error = Object.new
    error.define_singleton_method(:puts) { |_line| raise Errno::EPIPE, "closed" }
    command, = init_with(rows: [ inspection ], input: StringIO.new, error: error)

    assert_nil command.send(:emit_preflight_warnings, [ inspection ])
  end
end
