require "hive/provider_health/repository"

module Hive
  module ProviderHealth
    # Applies shared health only from immutable final attempt records. It owns
    # no task marker, retry, deadline, successor, or dispatch operation.
    class AttemptObserver
      def initialize(store:)
        unless store.is_a?(Repository)
          raise InvalidMutation, "attempt observer requires a provider-health repository"
        end

        @store = store
      end

      def observe(record)
        return :not_applicable unless explicit_final_record?(record)

        attempt = attempt_binding(record)
        receipt = receipt_identity(record)
        completion_results = complete_probes(record, attempt, receipt)
        evidence_data = record.receipt && record.receipt["provider_evidence"]
        return :acknowledged unless evidence_data

        evidence = Evidence.from_receipt(
          evidence_data,
          route: attempt.route,
          attempt_id: attempt.attempt_id
        )
        binding = attempt.probe_bindings.find { |candidate| candidate.scope == evidence.scope }
        expected_generation = if binding
          result = completion_results.fetch(binding.scope.key)
          return :acknowledged unless result.accepted? || result.duplicate?

          result.generation
        else
          circuit_generation(record, evidence.scope).fetch("observed_generation")
        end
        @store.apply_evidence(
          evidence: evidence,
          attempt: attempt,
          terminal_receipt: receipt,
          expected_generation: expected_generation
        )
        :acknowledged
      end

      private

      def explicit_final_record?(record)
        record && %w[terminal lost].include?(record.state) &&
          record["routing"].is_a?(Hash) && record["routing"]["mode"] == "explicit"
      end

      def complete_probes(record, attempt, receipt)
        return {} if attempt.probe_bindings.empty?

        outcome = if record.state == "lost"
          "lost"
        elsif record.receipt.fetch("outcome") == "succeeded"
          "success"
        elsif record.receipt.fetch("outcome") == "cancelled"
          "cancelled"
        else
          "failure"
        end
        attempt.probe_bindings.zip(
          @store.complete_probe(
            attempt: attempt,
            terminal_receipt: receipt,
            outcome: outcome
          )
        ).to_h { |binding, result| [ binding.scope.key, result ] }
      end

      def attempt_binding(record)
        routing = record["routing"]
        route = route_identity(routing.fetch("route"))
        AttemptBinding.new(
          attempt_id: record.attempt_id,
          task_generation: record.task_generation,
          ownership_fence: record.ownership_generation,
          route: route,
          probe_bindings: routing.fetch("probe_bindings").map { |data| probe_binding(data) }
        )
      end

      def route_identity(data)
        RouteIdentity.new(
          route_id: data.fetch("route_id"),
          account_id: data.fetch("provider_account_id"),
          adapter: data.fetch("adapter"),
          launch_binding_id: data.fetch("launch_binding_id"),
          model_id: data.fetch("model")
        )
      end

      def probe_binding(data)
        ProbeBinding.new(
          scope: ProviderHealth.scope_from_h(data.fetch("scope")),
          journal_epoch: data.fetch("journal_epoch"),
          observed_generation: data.fetch("observed_generation"),
          claim_generation: data.fetch("claim_generation"),
          attempt_id: data.fetch("attempt_id"),
          task_generation: data.fetch("task_generation"),
          ownership_fence: data.fetch("ownership_fence")
        )
      end

      def circuit_generation(record, scope)
        record["routing"].fetch("circuit_generations").find do |entry|
          ProviderHealth.scope_from_h(entry.fetch("scope")) == scope
        end || raise(InvalidMutation, "provider evidence has no enclosing circuit generation")
      end

      def receipt_identity(record)
        if record.state == "terminal"
          receipt = record.receipt
          {
            "attempt_id" => receipt.fetch("attempt_id"),
            "receipt_version" => receipt.fetch("receipt_version"),
            "terminal_lease_version" => receipt.fetch("terminal_lease_version")
          }.freeze
        else
          {
            "attempt_id" => record.attempt_id,
            "receipt_version" => 1,
            "terminal_lease_version" => record.lease_version
          }.freeze
        end
      end
    end
  end
end
