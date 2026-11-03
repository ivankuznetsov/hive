require "hive/task_capabilities/store"
require "hive/attempts/context"

module Hive
  module TaskCapabilities
    # Admission reads accepted state only; policy changes never repin a task.
    module Admission
      REASONS = %w[task_capability_invalid_selection task_capability_policy_conflict
        task_capability_missing_skill task_capability_verification_unavailable
        task_capability_approval_required task_capability_approval_scope
        task_capability_blocked task_capability_stale_preview
        task_capability_operator_required task_capability_route_unavailable
        task_capability_stale_revision task_capability_running_attempt].freeze
      GUIDANCE_STAGES = %w[plan execute].freeze

      class Error < Hive::Error
        attr_reader :reason
        def initialize(message, reason: "task_capability_blocked")
          @reason = reason
          super(message)
        end
        def exit_code = Hive::ExitCodes::USAGE
      end

      module_function

      def authorize_operator!
        return true unless Hive::Attempts::Context.operator_context?
        raise Error.new("task capability approval, waiver and acceptance require a human task creator or project owner; an active Hive attempt cannot authorize them",
                        reason: "task_capability_operator_required")
      end

      def skill_identity(binding, project_root:, cfg:)
        actor, skill = binding.values_at("actor", "skill")
        unless actor && skill
          raise Error.new("selected #{binding.fetch('id')} guidance requires a named installed compatible skill and exact actor binding; configure/install the skill or change the execution plan", reason: "task_capability_missing_skill")
        end
        profile = Hive::AgentProfiles.lookup(actor.fetch("profile"), cfg: cfg)
        invocation = profile.format_skill_invocation(skill)
        status, path = profile.verify_skill(invocation, project_root: project_root)
        unless status == :present && File.file?(path)
          raise Error.new("selected #{binding.fetch('id')} skill #{skill.inspect} is missing or incompatible: #{path}; configure/install it or change the execution plan", reason: "task_capability_missing_skill")
        end
        { "invocation" => invocation, "path" => File.realpath(path), "digest" => ::Digest::SHA256.file(path).hexdigest }
      end

      def verify_skill_binding!(binding, project_root:, cfg:)
        current = skill_identity(binding, project_root: project_root, cfg: cfg)
        unless binding["skill_identity"] == current
          raise Error.new("selected #{binding.fetch('id')} skill identity changed; restore the pinned skill or accept a revised execution plan", reason: "task_capability_missing_skill")
        end
        current.fetch("invocation")
      end

      def guidance_stage_supported?(workflow, name)
        GUIDANCE_STAGES.include?(name) && workflow.stage_named(name)&.execution_strategy == name.to_sym
      end

      def enforce!(task)
        return true unless task.respond_to?(:folder)
        unless Hive::Attempts::Context.operator_context?
          require "hive/task_capabilities/revision"
          Revision.new(task: task).activate_pending!
        end
        plan = Store.new(task.folder).current
        return true unless plan
        # A validated external closure retires the task without evaluating its
        # checks. Only the terminal archive runner may finish that protocol.
        if task.respond_to?(:workflow) && task.respond_to?(:stage_index) && task.stage_index == task.workflow.stages.last.index
          require "hive/task_closure"
          require "hive/task_capabilities/result_store"
          closure = Hive::TaskClosure.read(task, quarantine: false)
          if closure.valid? && ResultStore.new(task.folder).terminal_history.any? { |_digest, record| record["reference"] == "closure:#{closure.receipt.fetch('receipt_digest')}" }
            return true
          end
        end
        unsupported = plan.data.fetch("bindings").find do |binding|
          binding["kind"] == "guidance" && (!GUIDANCE_STAGES.include?(binding["stage"]) ||
            (task.respond_to?(:workflow) && !guidance_stage_supported?(task.workflow, binding["stage"])))
        end
        if unsupported
          raise Error.new("selected #{unsupported.fetch('id')} guidance has no execution attachment at #{unsupported['stage']}; change its execution-plan stage binding")
        end
        blockers = plan.data.fetch("blockers").reject { |entry| entry["phase"] == "finalization" }
        return true if blockers.empty?
        first = blockers.first
        reason = REASONS.include?(first["reason"]) ? first["reason"] : "task_capability_blocked"
        raise Error.new(blockers.map { |entry| entry.fetch("message") }.join("; "), reason: reason)
      end
    end
  end
end
