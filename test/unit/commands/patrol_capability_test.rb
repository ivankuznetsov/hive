require "test_helper"
require "hive/commands/patrol"
require "hive/commands/refactor_patrol"

class PatrolCapabilityCommandTest < Minitest::Test
  include HiveTestHelper

  class RecordingContext
    attr_reader :calls

    def initialize
      @calls = []
    end

    def method_missing(name, *arguments)
      @calls << [ name, *arguments ]
      true
    end

    def respond_to_missing?(*)
      true
    end
  end

  def test_default_dismissals_factory_preserves_dry_run_state
    with_tmp_dir do |root|
      state = Hive::Patrol::StateStore.new(root)
      command = Hive::Commands::Patrol.new("demo", dry_run: true)

      dismissals = command.instance_variable_get(
        :@dismissals_factory
      ).call(root, state)

      assert_instance_of Hive::Patrol::Dismissals, dismissals
      refute dismissals.instance_variable_get(:@persist)
    end
  end

  def test_patrol_declares_every_observation_and_mutation_capability
    command = Hive::Commands::Patrol.allocate
    context = RecordingContext.new
    command.instance_variable_set(:@capability_context, context)

    command.send(:require_module_observation_capabilities!)
    command.send(:require_module_mutation_capabilities!)

    assert_equal(
      [
        [ :require_filesystem_read!, "repository" ],
        [ :require_external_command!, "git" ],
        [ :require_filesystem_write!, ".hive-state/patrol/**" ],
        [ :require_repository_write! ],
        [ :require_filesystem_write!, ".hive-state/stages/**" ],
        [ :require_github_mutation!, "pull_requests" ],
        [ :require_external_command!, "gh" ],
        [ :require_network_host!, "api.github.com" ]
      ],
      context.calls
    )
  end

  def test_patrol_effect_capabilities_check_the_sink_specific_grants
    command = Hive::Commands::Patrol.allocate
    context = RecordingContext.new
    command.instance_variable_set(:@capability_context, context)

    assert command.send(:effect_capability_allowed?, capability: "repository_write")
    assert command.send(:effect_capability_allowed?, capability: "github_pull_requests")
    assert command.send(:effect_capability_allowed?, capability: "filesystem_write")
    assert command.send(:effect_capability_allowed?, capability: "review_handoff")
    refute command.send(:effect_capability_allowed?, capability: "unknown")
    assert_equal(
      [
        [ :require_repository_write! ],
        [ :require_github_mutation!, "pull_requests" ],
        [ :require_external_command!, "gh" ],
        [ :require_network_host!, "api.github.com" ],
        [ :require_filesystem_write!, ".hive-state/patrol/**" ],
        [ :require_filesystem_write!, ".hive-state/stages/**" ]
      ],
      context.calls
    )
  end

  def test_patrol_effect_capability_denial_returns_false
    command = Hive::Commands::Patrol.allocate
    context = RecordingContext.new
    context.define_singleton_method(:require_repository_write!) do
      raise Hive::Modules::CapabilityDenied, "repository write denied"
    end

    refute command.send(
      :effect_capability_allowed?,
      capability: "repository_write",
      capability_context: context
    )
  end

  def test_architecture_patrol_declares_every_observation_and_mutation_capability
    command = Hive::Commands::RefactorPatrol.allocate
    context = RecordingContext.new
    command.instance_variable_set(:@capability_context, context)

    command.send(:require_module_observation_capabilities!)
    command.send(:require_module_mutation_capabilities!)

    assert_equal(
      [
        [ :require_filesystem_read!, "repository" ],
        [ :require_external_command!, "git" ],
        [ :require_repository_write! ],
        [ :require_filesystem_write!, ".hive-state/refactor_patrol/**" ],
        [ :require_filesystem_write!, ".hive-state/stages/**" ],
        [ :require_github_mutation!, "issues" ],
        [ :require_github_mutation!, "pull_requests" ],
        [ :require_external_command!, "gh" ],
        [ :require_network_host!, "api.github.com" ]
      ],
      context.calls
    )
  end
end
