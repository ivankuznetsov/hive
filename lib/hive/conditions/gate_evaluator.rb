require "hive/conditions/policy"

module Hive
  module Conditions
    GateResult = Data.define(:status, :transition, :diagnostics, :waivers) do
      def eligible? = status == :eligible
      def reconcile_required? = status == :reconcile_required

      def to_h
        {
          "status" => status.to_s,
          "transition" => transition,
          "diagnostics" => diagnostics,
          "waivers" => waivers
        }
      end
    end

    class GateEvaluator
      def initialize(projection:, rule:)
        @projection = projection.respond_to?(:to_h) ? projection.to_h : projection
        @rule = rule
      end

      def evaluate(research: false, research_evidence: false)
        diagnostics = []
        waivers = []
        @rule.required.each do |name|
          fact = current(name)
          next if terminal_agent_health_informational?(name, fact)
          next if fact && fact["state"] == "satisfied"
          if research_waiver?(name, fact, research: research, research_evidence: research_evidence)
            waivers << {
              "condition" => name,
              "reason" => "no_commit_success",
              "evidence_reason" => fact["reason"]
            }
            next
          end

          diagnostics << diagnostic(name, fact, role: "requirement")
        end
        @rule.inhibitors.each do |name|
          fact = current(name)
          next if fact && fact["state"] == "unsatisfied"
          next if fact && fact["state"] != "satisfied" && fact["state"] != "pending" &&
                  fact["state"] != "unverifiable"

          diagnostics << diagnostic(name, fact, role: "inhibitor")
        end

        status = if diagnostics.empty?
          :eligible
        elsif diagnostics.any? { |entry| entry["state"] == "pending" || entry["state"] == "missing" }
          :reconcile_required
        else
          :blocked
        end
        GateResult.new(
          status: status, transition: @rule.transition,
          diagnostics: diagnostics.freeze, waivers: waivers.freeze
        )
      end

      private

      def current(name)
        @projection.dig("conditions", "current")&.find { |fact| fact["condition"] == name }
      end

      def diagnostic(name, fact, role:)
        state = fact ? fact["state"] : "missing"
        {
          "condition" => name,
          "role" => role,
          "state" => state,
          "reason" => fact&.fetch("reason", nil),
          "code" => state == "pending" || state == "missing" ? "unknown/reconcile_required" :
            "condition_#{state}"
        }
      end

      def terminal_agent_health_informational?(name, fact)
        name == "AgentHealthy" && fact&.dig("payload", "informational_after_terminal") == true
      end

      def research_waiver?(name, fact, research:, research_evidence:)
        name == "ChangesPresent" &&
          @rule.options["no_commit_success"] == true &&
          research && research_evidence &&
          fact&.fetch("state", nil) == "unsatisfied" &&
          fact&.fetch("reason", nil) == "research_no_commit"
      end
    end
  end
end
