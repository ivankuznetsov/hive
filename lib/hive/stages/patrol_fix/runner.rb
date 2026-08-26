require "hive/patrol_fix/runner"
require "hive/stages/managed_agent_custody"

module Hive
  module Stages
    module PatrolFix
      # Stage-layer boundary around the Patrol Fix core controller. It keeps
      # Attempts diagnostic transport out of the workflow core while ensuring
      # every controller exception has one chance to publish semantic facts.
      module Runner
        module_function

        def run!(task, cfg = nil, **kwargs)
          Hive::PatrolFix::Runner.run!(task, cfg, **kwargs)
        rescue StandardError => error
          begin
            Hive::Stages::ManagedAgentCustody.publish_controller_failure(
              stage: task.stage_name, error: error
            )
          rescue StandardError
            nil
          end
          raise
        end
      end
    end
  end
end
