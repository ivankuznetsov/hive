require "hive"
require "hive/workflows"
require "hive/workflows/registry"

module Hive
  module Stages
    module Resolver
      # Runner table keyed by each stage descriptor's INTERNAL EXECUTION
      # STRATEGY (`Hive::Workflow::Stage#execution_strategy`) — never by stage
      # name and never by workflow identity. Descriptors own selection:
      #   - Workflows::Coding pins its bespoke runners with an explicit
      #     `runner:` key per stage in its DESCRIPTOR;
      #   - every other active stage derives a generic strategy from `kind`
      #     (:agent, :council, :controller);
      #   - everything else derives nil and raises StageError at dispatch.
      #
      # Because dispatch reads only the resolved stage's own declaration, a
      # non-coding stage that happens to share a NAME with a coding stage
      # (e.g. content's terminal "done" agent) resolves by its own kind — no
      # `coding_id?` guard and no name-first precedence needed.
      RUNNERS = {
        agent: lambda {
          require "hive/stages/agent"
          Hive::Stages::Agent.method(:run!)
        },
        council: lambda {
          require "hive/stages/council"
          Hive::Stages::Council.method(:run!)
        },
        inbox: lambda {
          require "hive/stages/inbox"
          Hive::Stages::Inbox.method(:run!)
        },
        brainstorm: lambda {
          require "hive/stages/brainstorm"
          Hive::Stages::Brainstorm.method(:run!)
        },
        plan: lambda {
          require "hive/stages/plan"
          Hive::Stages::Plan.method(:run!)
        },
        execute: lambda {
          require "hive/stages/execute"
          Hive::Stages::Execute.method(:run!)
        },
        "open-pr": lambda {
          require "hive/stages/open_pr"
          Hive::Stages::OpenPr.method(:run!)
        },
        review: lambda {
          require "hive/stages/review"
          Hive::Stages::Review.method(:run!)
        },
        artifacts: lambda {
          require "hive/stages/artifacts"
          Hive::Stages::Artifacts.method(:run!)
        },
        finalize: lambda {
          require "hive/stages/finalize"
          Hive::Stages::Finalize.method(:run!)
        },
        done: lambda {
          require "hive/stages/done"
          Hive::Stages::Done.method(:run!)
        }
      }.freeze

      CONTROLLER_RUNNERS = {
        patrol_fix: lambda {
          require "hive/stages/patrol_fix/runner"
          Hive::Stages::PatrolFix::Runner.method(:run!)
        }
      }.freeze

      module_function

      def resolve(task, descriptor: Hive::Workflows::Registry.default)
        strategy = descriptor.stage_named(task.stage_name)&.execution_strategy

        if strategy == :controller && descriptor.controller
          runner = CONTROLLER_RUNNERS[descriptor.controller]
          return runner.call if runner
        end

        runner = RUNNERS[strategy]
        return runner.call if runner

        raise Hive::StageError, "no runner for stage #{task.stage_name}"
      end
    end
  end
end
