require "json"
require "shellwords"

module Hive
  module TaskCapabilities
    # The operator's next step is identical in preview, capture and inspection.
    class BlockerFormatter
      def initialize(target: "<TASK>", project: "<PROJECT>", expected: nil)
        @target, @project, @expected = target, project, expected || {}
      end

      def call(blocker)
        id = blocker["capability"] || blocker["capability_id"] || "qa"
        reason = blocker.fetch("reason", "task_capability_blocked")
        command = nil
        alternative = nil
        recovery = case reason
        when "task_capability_route_unavailable"
          "Finalization is blocked: restore the exact approved route or archive/cancel this task. Unrelated implementation and review may continue."
        when "task_capability_approval_required", "task_capability_approval_scope"
          command = correction("propose", "--select", "#{id}=on", "--task-approval", "#{id}=<REFERENCE>", "--reason", "<AUTHORITY_REASON>")
          alternative = correction("propose", "--select", "#{id}=on", "--capability-approval", "#{id}=<CAPTURED_REFERENCE>")
          "Propose the exact captured actor, permissions, local targets, budget and timeout for operator approval; inspect and explicitly accept the proposal."
        when "task_capability_missing_skill"
          command = correction("propose", "--select", "#{id}=on", "--reason", "<SKILL_INSTALLATION_REASON>")
          "Install/configure the named compatible skill, then propose its exact content and explicitly accept the proposal."
        when "task_capability_verification_unavailable"
          command = correction("propose", "--verification-plan", "<CHECKS_JSON>", "--reason", "<CHECK_REASON>")
          alternative = correction("waive", "--reason", "<QA_WAIVER_REASON>", "--checks", "all") if id == "qa"
          "Configure verification or declare a usable check within the captured permissions, then explicitly accept the proposal.#{id == 'qa' ? ' Alternatively record a per-task QA waiver with a reason and all affected checks.' : ''}"
        when "task_capability_policy_conflict"
          command = correction("propose", "--select", "#{id}=on", "--reason", "<POLICY_REASON>")
          "Select the required capability and explicitly accept the proposal; project policy cannot be waived by a task selection."
        else
          command = Shellwords.join([ "hive", "task-capabilities", "show", @target, "--project", @project, "--json" ])
          "Inspect the pinned plan and restore its prerequisites, then rerun the affected stage."
        end
        { "capability_id" => id, "reason" => reason,
          "message" => [ blocker["message"], recovery ].compact.join(" "),
          "command" => command, "alternative_command" => alternative }
      end

      private

      def correction(action, *options)
        identity = @expected["expected_identity"] || "<TASK_IDENTITY_JSON>"
        identity = JSON.generate(identity) if identity.is_a?(Hash)
        Shellwords.join([ "hive", "task-capabilities", action, @target, "--project", @project,
          "--identity", identity, "--plan-version", (@expected["expected_version"] || "<PLAN_VERSION>").to_s,
          "--sha", @expected["expected_sha"] || "<CURRENT_SHA>", *options ])
      end
    end
  end
end
