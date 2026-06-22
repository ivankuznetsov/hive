require "hive"
require "hive/workflows"
require "hive/workflows/registry"

module Hive
  module Stages
    module Resolver
      CODING_RUNNERS = {
        "inbox" => lambda {
          require "hive/stages/inbox"
          Hive::Stages::Inbox.method(:run!)
        },
        "brainstorm" => lambda {
          require "hive/stages/brainstorm"
          Hive::Stages::Brainstorm.method(:run!)
        },
        "plan" => lambda {
          require "hive/stages/plan"
          Hive::Stages::Plan.method(:run!)
        },
        "execute" => lambda {
          require "hive/stages/execute"
          Hive::Stages::Execute.method(:run!)
        },
        "open-pr" => lambda {
          require "hive/stages/open_pr"
          Hive::Stages::OpenPr.method(:run!)
        },
        "review" => lambda {
          require "hive/stages/review"
          Hive::Stages::Review.method(:run!)
        },
        "artifacts" => lambda {
          require "hive/stages/artifacts"
          Hive::Stages::Artifacts.method(:run!)
        },
        "finalize" => lambda {
          require "hive/stages/finalize"
          Hive::Stages::Finalize.method(:run!)
        },
        "done" => lambda {
          require "hive/stages/done"
          Hive::Stages::Done.method(:run!)
        }
      }.freeze

      module_function

      def resolve(task, descriptor: Hive::Workflows::Registry.default)
        # Coding keeps name-first precedence so brainstorm/plan stay on their
        # bespoke runners even though they are declared kind: :agent in the
        # coding descriptor. Non-coding workflows must route by their own
        # descriptor kind, even when a stage name collides with a coding stage.
        if Hive::Workflows.coding_id?(descriptor.id)
          runner = CODING_RUNNERS[task.stage_name]
          return runner.call if runner
        end

        stage = descriptor.stages.find { |candidate| candidate.name == task.stage_name }
        if stage&.kind == :agent
          require "hive/stages/agent"
          return Hive::Stages::Agent.method(:run!)
        end

        raise Hive::StageError, "no runner for stage #{task.stage_name}"
      end
    end
  end
end
