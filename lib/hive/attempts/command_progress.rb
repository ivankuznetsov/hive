require "digest"
require "hive/canonical_json"

module Hive
  module Attempts
    # Command owners may contribute a semantic progress token when their state
    # advances independently of the task artifact. The generic dispatcher
    # asks this interface instead of knowing plan-review file layout or
    # special-casing current.json bytes itself.
    module CommandProgress
      # Same-stage owner commands the daemon re-runs while their task row stays
      # runnable. Their unchanged generation must pace and then stop repeated
      # failures instead of admitting a fresh worker on every tick.
      FAILURE_LADDER_COMMANDS = %w[plan-review-run].freeze

      module_function

      def failure_ladder?(argv)
        FAILURE_LADDER_COMMANDS.include?(Array(argv)[1].to_s)
      end

      # `runtime_digest` binds owner-command generations to the Hive build, so
      # a deployment that fixes a deterministic failure starts a fresh series.
      def token_for(argv:, task:, fallback:, runtime_digest: nil)
        return task_token_for(task: task, fallback: fallback) if task_progress?(task)

        case Array(argv)[1].to_s
        when "plan-review-run"
          require "hive/plan_review/store"
          Hive::CanonicalJSON.digest(
            "artifact" => fallback,
            "command" => "plan-review-run",
            "owner_progress" => Hive::PlanReview::Store.new(
              task_folder: task_folder(task)
            ).progress_token,
            "runtime" => runtime_digest
          )
        when "proposal"
          Hive::CanonicalJSON.digest(
            "artifact" => fallback,
            "command" => Array(argv).map(&:to_s),
            "input_digest" => proposal_input_digest(argv)
          )
        else
          fallback
        end
      end

      # Proposal source workers are always admitted with the controller-built
      # `--input ABSOLUTE_PATH` pair (Commands::Proposal#source_worker_argv).
      def proposal_input_digest(argv)
        values = Array(argv).map(&:to_s)
        index = values.rindex("--input")
        path = index && values[index + 1]
        return unless path && File.file?(path) && !File.symlink?(path)

        ::Digest::SHA256.file(path).hexdigest
      rescue SystemCallError, IOError
        nil
      end

      def task_progress?(task)
        patrol_fix?(task)
      end

      def task_token_for(task:, fallback:)
        return fallback unless task_progress?(task)

        patrol_fix_token(task, fallback)
      end

      def patrol_fix?(task)
        return false unless task.respond_to?(:workflow)

        workflow = task.workflow
        workflow.respond_to?(:controller) && workflow.controller == :patrol_fix
      end

      def patrol_fix_token(task, fallback)
        require "hive/patrol_fix/receipt_store"
        Hive::CanonicalJSON.digest(
          "artifact" => fallback,
          "workflow" => "patrol-fix",
          "owner_progress" => Hive::PatrolFix::ReceiptStore.new(
            task_folder: task_folder(task)
          ).progress_token
        )
      end

      def task_folder(task)
        task.respond_to?(:folder) && task.folder ? task.folder : File.dirname(task.state_file)
      end
    end
  end
end
