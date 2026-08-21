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
        [ :require_filesystem_write!, ".hive-state/patrol/**" ]
      ],
      context.calls
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
        [ :require_filesystem_write!, ".hive-state/refactor_patrol/**" ]
      ],
      context.calls
    )
  end
end
