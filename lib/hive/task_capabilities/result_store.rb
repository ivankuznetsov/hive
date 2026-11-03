require "hive/task_capabilities/result"
require "hive/task_capabilities/store"
require "hive/task_capabilities/actor_runner"
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
        validated_records.filter_map do |digest, data|
          next if data["record_type"]
          result = Result.new(data)
          raise Result::Invalid, "accepted verification identity changed" unless result.digest == digest
          [ digest, result ]
        end
      end

      # Terminal records describe custody, never check success or a waiver.
      def terminal_history
        validated_records.select { |_digest, data| data["record_type"] == "terminal" }
      end

      def record_terminal!(disposition:, reference:)
        plan = @store.current
        return nil unless plan
        label = disposition == "cancelled" ? "Cancelled — gate not evaluated" : "Closed out-of-band — gate not evaluated"
        data = { "schema_version" => 1, "record_type" => "terminal", "task" => plan.data.fetch("task"),
          "execution_plan_digest" => plan.digest, "disposition" => disposition, "reference" => reference, "label" => label }
        validate_record!(data)
        @store.accept_blob("result", data)
      end

      def record_equivalence!(plan_digest:, result_digest:, proof:)
        plan = @store.current
        raise Result::Invalid, "equivalence plan changed" unless plan && plan.digest == plan_digest
        data = { "schema_version" => 1, "record_type" => "equivalence", "task" => plan.data.fetch("task"),
          "execution_plan_digest" => plan.digest, "result_digest" => result_digest, "proof" => proof }
        validate_record!(data)
        @store.accept_blob("result", data)
      end

      def disposition_history
        validated_records.select { |_digest, data| data["record_type"] == "finding-disposition" }
      end

      def record_disposition!(result_digest:, finding_ids:, reference:)
        Admission.authorize_operator!
        plan = @store.current || raise(Result::Invalid, "disposition requires an adopted execution plan")
        data = { "schema_version" => 1, "record_type" => "finding-disposition", "task" => plan.data.fetch("task"),
          "execution_plan_digest" => plan.digest, "result_digest" => result_digest,
          "finding_ids" => finding_ids, "reference" => reference, "disposition" => "risk-accepted" }
        validate_record!(data)
        @store.accept_blob("result", data)
      end

      def current(binding:, check:, plan:, sha:, environment:, task_delta: :unobserved)
        candidate = history.reverse.find do |_digest, result|
          value = result.data
          value["task"] == plan.data.fetch("task") &&
            value["capability_id"] == binding.fetch("id") && value["check_id"] == check.fetch("id")
        end
        return { "state" => "pending" } unless candidate
        digest, result = candidate
        value = result.data
        fresh = value["evaluated_sha"] == sha && value["check_digest"] == Result.check_digest(binding, check) && dependencies_match?(result: value, plan: plan, binding: binding, check: check) && value["environment_digest"] == Result.digest(environment) &&
          (task_delta == :unobserved || Result.same_base_context?(value["task_delta"], task_delta))
        { "state" => fresh ? result.state : "stale", "result_digest" => digest, "result" => value }
      end

      def dependencies_match?(result:, plan:, binding:, check:)
        previous = @store.read_plan(result.fetch("execution_plan_digest"))
        old_binding = previous.data.fetch("bindings").find { |entry| entry["id"] == binding["id"] && entry["stage"] == binding["stage"] }
        old_check = old_binding && old_binding.fetch("checks").find { |entry| entry["id"] == check["id"] }
        dependency_fingerprint(plan, binding, check) == dependency_fingerprint(previous, old_binding, old_check)
      end

      # This is read state, consumed by the finalization gate separately. It
      # does not authorize a transition or turn an out-of-band closure green.
      def aggregate(plan:, sha:, environment:, task_delta: :unobserved)
        capabilities = plan.data.fetch("bindings").select { |binding| binding["kind"] == "verification" }.map do |binding|
          checks = binding.fetch("checks").map do |check|
            current(binding: binding, check: check, plan: plan, sha: sha, environment: environment, task_delta: task_delta).merge("capability_id" => binding.fetch("id"), "check_id" => check.fetch("id"), "kind" => check.fetch("kind"))
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

      def dependency_fingerprint(plan, binding, check)
        return nil unless binding && check
        checks = binding.fetch("checks")
        dependencies = check.fetch("depends_on", []).map do |id|
          prerequisite = checks.find { |entry| entry["id"] == id }
          [ id, prerequisite && Result.check_digest(binding, prerequisite), prerequisite && dependency_fingerprint(plan, binding, prerequisite) ]
        end
        capabilities = binding.fetch("depends_on", []).map do |id|
          prerequisite = plan.data.fetch("bindings").select { |entry| entry["id"] == id }
          [ id, prerequisite ]
        end
        Result.digest("checks" => dependencies, "capabilities" => capabilities)
      end

      def validated_records
        @store.blobs("result").each do |digest, data|
          raise Result::Invalid, "accepted result identity changed" unless Result.digest(data) == digest
          if data["record_type"]
            validate_record!(data)
          else
            result = Result.new(data)
            validate_plan!(result)
            validate_evidence!(result)
          end
        end
      end

      def validate_record!(data)
        plan = @store.read_plan(data.fetch("execution_plan_digest"))
        raise Result::Invalid, "capability record task mismatch" unless data["task"] == plan.data.fetch("task") && data["schema_version"] == 1
        common = %w[schema_version record_type task execution_plan_digest]
        case data["record_type"]
        when "terminal"
          label = data["disposition"] == "cancelled" ? "Cancelled — gate not evaluated" : "Closed out-of-band — gate not evaluated"
          unless data.keys.sort == (common + %w[disposition reference label]).sort && %w[cancelled closed-out-of-band].include?(data["disposition"]) &&
              data["reference"].is_a?(String) && !data["reference"].empty? && data["reference"].bytesize <= 2048 && data["label"] == label
            raise Result::Invalid, "invalid capability terminal disposition"
          end
        when "finding-disposition"
          unless data.keys.sort == (common + %w[result_digest finding_ids reference disposition]).sort && data["disposition"] == "risk-accepted" &&
              data["reference"].is_a?(String) && !data["reference"].strip.empty? && data["reference"].bytesize <= 2048 &&
              data["finding_ids"].is_a?(Array) && !data["finding_ids"].empty? && data["finding_ids"].uniq == data["finding_ids"]
            raise Result::Invalid, "invalid finding-scoped risk disposition"
          end
          original = Result.new(@store.read_blob("result", data.fetch("result_digest")))
          validate_plan!(original)
          ids = original.data.fetch("findings").map { |finding| finding.fetch("id") }
          unless original.state == "failed" && original.data["capability_id"] == "security" && (data["finding_ids"] - ids).empty?
            raise Result::Invalid, "risk disposition requires actual failed security findings; unrun or unavailable checks cannot be waived"
          end
        when "equivalence"
          unless data.keys.sort == (common + %w[result_digest proof]).sort && data["proof"].is_a?(Hash) && data["proof"].keys.sort == %w[new_delta new_sha old_delta old_sha]
            raise Result::Invalid, "invalid capability equivalence receipt"
          end
          original = Result.new(@store.read_blob("result", data.fetch("result_digest")))
          validate_plan!(original)
          proof = data.fetch("proof")
          unless original.state == "passed" && original.data["evaluated_sha"] == proof["old_sha"] && original.data["task_delta"] == proof["old_delta"] &&
              Hive::AgentGitGate::OID.match?(proof["new_sha"].to_s) && Result.equivalent_delta?(proof["old_delta"], proof["new_delta"])
            raise Result::Invalid, "unproven capability equivalence"
          end
        else
          raise Result::Invalid, "unknown capability result record type"
        end
      end

      def validate_plan!(result)
        value = result.data
        plan = @store.read_plan(value.fetch("execution_plan_digest"))
        binding = plan.data.fetch("bindings").find { |entry| entry["id"] == value["capability_id"] && entry["kind"] == "verification" && entry["stage"] == "review" }
        check = binding && binding.fetch("checks").find { |entry| entry["id"] == value["check_id"] }
        unless check && value["task"] == plan.data.fetch("task") && value["kind"] == check["kind"] && value["claim"] == check["claim"] &&
            value["runner"] == check.fetch("runner", {}) && value["check_digest"] == Result.check_digest(binding, check)
          raise Result::Invalid, "verification result does not match its accepted planned check"
        end
        actor_binding = check.dig("runner", "actor_binding") || binding
        if value.key?("observed_route") && (!actor_binding["actor"] || !ActorRunner.route_matches?(actor_binding.fetch("actor_route"), value.fetch("observed_route"), actor_binding.fetch("actor")))
          raise Result::Invalid, "observed actor route differs from its accepted binding"
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
