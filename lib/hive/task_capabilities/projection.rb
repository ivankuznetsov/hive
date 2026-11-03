require "hive/task_capabilities/gate"
require "hive/task_capabilities/revision"
require "hive/task_capabilities/blocker_formatter"

module Hive
  module TaskCapabilities
    # One bounded, persisted read model for task HTML and CLI inspection.
    # Full instructions, runner environments and command output stay in custody.
    class Projection
      LABELS = { "pending" => "Pending check", "running" => "Check running", "passed" => "Passed",
        "failed" => "Failed", "blocked" => "Blocked", "not-applicable" => "Not applicable",
        "stale" => "Stale — rerun required", "waived" => "Waived by operator" }.freeze
      LIMIT = 100

      def initialize(task:, cfg:, project: nil)
        @task, @cfg, @project = task, cfg, project || File.basename(task.respond_to?(:project_root) ? task.project_root : "project")
      end

      def call
        revision = Revision.new(task: @task).show
        return nil unless revision["plan"]
        plan = revision.fetch("plan")
        gate = Gate.new(task: @task, cfg: @cfg || Hive::Config.load(@task.project_root)).read_state
        summary = Gate.summary(gate)
        formatter = BlockerFormatter.new(target: @task.slug, project: @project, expected: revision["expected"])
        blockers = plan.fetch("blockers").dup
        gate.fetch("capabilities").each do |item|
          next unless item["state"] == "blocked" && item["reason"] && blockers.none? { |blocker| blocker["capability"] == item["id"] }
          blockers << { "capability" => item.fetch("id"), "reason" => item["id"] == "security" ? "task_capability_route_unavailable" : "task_capability_verification_unavailable", "message" => item.fetch("reason") }
        end
        checks = gate.fetch("checks").first(LIMIT).map { |check| project_check(check) }
        unavailable = revision["mutation_unavailable"]
        unavailable ||= "Task still has an owning attempt; wait for terminal publication before accepting." if Hive::Attempts::Repository.open_default(create_directories: false).live_attempt_for(task_id: @task.id.to_s)
        { "execution_plan_version" => plan.fetch("version"), "execution_plan_digest" => revision.fetch("execution_plan_digest"),
          "configuration_digest" => plan.fetch("configuration_digest"), "catalog_digest" => plan.fetch("catalog_digest"),
          "choices" => plan.fetch("choices"), "bindings" => plan.fetch("bindings").first(LIMIT).map { |binding| project_binding(binding) },
          "waivers" => plan.fetch("waivers").first(LIMIT).map { |waiver| waiver.except("capability", "check_fingerprints").merge("capability_id" => waiver.fetch("capability")) },
          "blockers" => blockers.first(LIMIT).map { |blocker| formatter.call(blocker) },
          "history" => revision.fetch("history").last(LIMIT), "required_stages" => revision.fetch("required_stages"),
          "expected" => revision["expected"], "mutation_unavailable" => unavailable,
          "proposals" => revision.fetch("proposals").last(LIMIT).map { |proposal| project_proposal(proposal, revision, unavailable) },
          "gate" => summary.merge("checks" => checks, "label" => LABELS.fetch(gate.fetch("state"), "Blocked")),
          "refresh_digest" => Result.digest(summary) }
      end

      private

      def project_binding(binding)
        binding.slice("id", "kind", "stage", "skill", "actor", "permissions", "targets", "budget_usd", "timeout_sec", "approval_reference").merge(
          "checks" => binding.fetch("checks", []).first(LIMIT).map { |check| check.slice("id", "kind", "claim", "depends_on") },
          "skill_digest" => binding.dig("skill_identity", "digest"))
      end

      def project_check(check)
        result = check.fetch("result", {})
        check.slice("capability_id", "check_id", "kind", "state", "result_digest", "disposition", "dispositions", "reason").merge(
          "label" => LABELS.fetch(check.fetch("state")),
          "reason" => check["reason"] || result["reason"], "claim" => result["claim"],
          "evaluated_sha" => result["evaluated_sha"], "parent_attempt_id" => result["parent_attempt_id"],
          "evidence" => result.fetch("evidence", []).first(LIMIT).map { |item| item.slice("kind", "reference", "digest", "sha256", "exit_status") },
          "findings" => result.fetch("findings", []).first(LIMIT).map do |finding|
            result.dig("runner", "type") == "command" ? finding.except("details").merge("details" => "Inspect immutable result #{check['result_digest']} for command evidence.") : finding
          end, "applicability" => result.fetch("applicability", {}))
      end

      def project_proposal(proposal, revision, unavailable)
        stale = proposal["base_digest"] != revision["execution_plan_digest"] || proposal["expected_sha"] != revision.dig("expected", "expected_sha")
        { "proposal_digest" => proposal.fetch("proposal_digest"), "status" => proposal.fetch("status"),
          "reason" => proposal.dig("input", "reason"), "selections" => proposal.dig("input", "selections"),
          "approval_previews" => proposal.fetch("input").fetch("approval_previews", []).map do |approval|
            approval.slice("reference", "digest").merge("envelope" => approval.fetch("envelope").except("capability").merge("capability_id" => approval.dig("envelope", "capability")))
          end,
          "disabled_reason" => unavailable || ("Task identity, execution-plan version or Git revision changed; refresh before accepting." if stale) }
      end
    end
  end
end
