require "hive/task_capabilities/result"
require "hive/task_capabilities/store"
require "hive/artifacts/outcome_evidence/contract"

module Hive
  module TaskCapabilities
    # Uses the existing protected accepted chain. Listing a directory cannot
    # establish authority, and every projection revalidates accepted bytes.
    class ResultStore
      def initialize(task_folder)
        @folder = task_folder
        @store = Store.new(task_folder)
      end

      def accept(result, observation: nil)
        validate_plan!(result)
        validate_evidence!(result)
        @store.accept_blob("result", result.to_h, observation: observation)
      end

      def history
        @store.blobs("result").map do |digest, data|
          result = Result.new(data)
          raise Result::Invalid, "accepted verification identity changed" unless result.digest == digest
          validate_plan!(result)
          validate_evidence!(result)
          [ digest, result ]
        end
      end

      def current(binding:, check:, plan:, sha:, environment:)
        candidate = history.reverse.find do |_digest, result|
          value = result.data
          value["task"] == plan.data.fetch("task") && value["execution_plan_digest"] == plan.digest &&
            value["capability_id"] == binding.fetch("id") && value["check_id"] == check.fetch("id")
        end
        return { "state" => "pending" } unless candidate
        digest, result = candidate
        value = result.data
        fresh = value["evaluated_sha"] == sha && value["check_digest"] == Result.check_digest(binding, check) && value["environment_digest"] == Result.digest(environment)
        { "state" => fresh ? result.state : "stale", "result_digest" => digest, "result" => value }
      end

      # This is read state, consumed by the finalization gate separately. It
      # does not authorize a transition or turn an out-of-band closure green.
      def aggregate(plan:, sha:, environment:)
        capabilities = plan.data.fetch("bindings").select { |binding| binding["kind"] == "verification" }.map do |binding|
          checks = binding.fetch("checks").map do |check|
            current(binding: binding, check: check, plan: plan, sha: sha, environment: environment).merge("capability_id" => binding.fetch("id"), "check_id" => check.fetch("id"), "kind" => check.fetch("kind"))
          end
          state = aggregate_state(checks)
          if binding["id"] == "qa" && state == "passed" && checks.none? { |check| check["kind"] == "behavior" && check["state"] == "passed" }
            state = "blocked"
          end
          { "id" => binding.fetch("id"), "state" => state, "checks" => checks }
        end
        plan.data.fetch("waivers").each do |waiver|
          capabilities << { "id" => waiver.fetch("capability"), "state" => "waived", "waiver" => waiver, "checks" => [] }
        end
        # Required selections denied at capture have no binding or waiver.
        plan.data.fetch("blockers").each do |blocker|
          existing = capabilities.find { |capability| capability["id"] == blocker["capability"] }
          if existing
            existing["state"] = "blocked" if existing["checks"].empty?
          else
            capabilities << { "id" => blocker.fetch("capability"), "state" => "blocked", "checks" => [], "reason" => blocker.fetch("message") }
          end
        end
        checks = capabilities.flat_map { |capability| capability.fetch("checks") }
        states = capabilities.map { |capability| capability.fetch("state") }
        state = if states.empty?
          "blocked"
        elsif states.all? { |item| %w[passed waived].include?(item) }
          states.include?("waived") ? "waived" : "passed"
        else
          aggregate_state(capabilities)
        end
        { "state" => state, "execution_plan_digest" => plan.digest, "evaluated_sha" => sha, "capabilities" => capabilities, "checks" => checks }
      end

      private

      def validate_plan!(result)
        value = result.data
        plan = @store.read_plan(value.fetch("execution_plan_digest"))
        binding = plan.data.fetch("bindings").find { |entry| entry["id"] == value["capability_id"] && entry["kind"] == "verification" && entry["stage"] == "review" }
        check = binding && binding.fetch("checks").find { |entry| entry["id"] == value["check_id"] }
        unless check && value["task"] == plan.data.fetch("task") && value["kind"] == check["kind"] && value["claim"] == check["claim"] &&
            value["runner"] == check.fetch("runner", {}) && value["check_digest"] == Result.check_digest(binding, check)
          raise Result::Invalid, "verification result does not match its accepted planned check"
        end
        if %w[passed failed not-applicable].include?(result.state) && value.dig("runner", "type") == "actor" &&
            (!value["spawn_id"] || value.fetch("evidence").any? { |entry| entry["kind"] != "outcome" })
          raise Result::Invalid, "actor verification requires correlated outcome evidence"
        end
        if %w[passed failed].include?(result.state) && value.dig("runner", "type") == "command" &&
            !(value.fetch("evidence").one? && value.fetch("evidence").first["kind"] == "command")
          raise Result::Invalid, "command verification requires its observed command exit"
        end
      end

      def aggregate_state(items)
        return "blocked" if items.empty?
        states = items.map { |item| item.fetch("state") }
        return "passed" if states.all? { |state| %w[passed not-applicable waived].include?(state) }
        %w[blocked failed stale running pending].find { |state| states.include?(state) }
      end

      def validate_evidence!(result)
        result.data.fetch("evidence").select { |entry| entry["kind"] == "outcome" }.each do |entry|
          Hive::Artifacts::OutcomeEvidence::Contract.verification!(entry.fetch("proof"), task_folder: @folder, check_id: result.data.fetch("check_id"), expected_head: result.data.fetch("evaluated_sha"))
        end
      end
    end
  end
end
