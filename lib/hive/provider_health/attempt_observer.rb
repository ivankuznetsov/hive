require "hive/provider_health/repository"

module Hive
  module ProviderHealth
    class AttemptObserver
      def initialize(store:)
        raise InvalidMutation, "attempt observer requires a provider-health repository" unless
          store.is_a?(Repository)
        @store = store
      end

      def observe(record)
        return :not_applicable unless explicit_final?(record)

        attempt = binding(record)
        receipt = receipt(record)
        completed = complete_probes(record, attempt, receipt)
        data = record.receipt && record.receipt["provider_evidence"]
        return :acknowledged unless data

        evidence = Evidence.from_receipt(data, route: attempt.route, attempt_id: attempt.attempt_id)
        probe = attempt.probe_bindings.find { |candidate| candidate.scope == evidence.scope }
        generation = if probe
          result = completed.fetch(probe.scope.key)
          return :acknowledged unless result.accepted? || result.duplicate?
          result.generation
        else
          circuit_generation(record, evidence.scope).fetch("observed_generation")
        end
        @store.apply_evidence(
          evidence: evidence, attempt: attempt, terminal_receipt: receipt,
          expected_generation: generation
        )
        :acknowledged
      end

      private

      def explicit_final?(record)
        record && %w[terminal lost].include?(record.state) &&
          record["routing"].is_a?(Hash) && record["routing"]["mode"] == "explicit"
      end

      def binding(record)
        routing = record["routing"]
        AttemptBinding.new(
          attempt_id: record.attempt_id, task_generation: record.task_generation,
          ownership_fence: record.ownership_generation,
          route: RouteIdentity.from_h(routing.fetch("route")),
          probe_bindings: routing.fetch("probe_bindings").map { |data| ProbeBinding.from_h(data) }
        )
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
        results = @store.complete_probe(
          attempt: attempt, terminal_receipt: receipt, outcome: outcome
        )
        attempt.probe_bindings.zip(results).to_h { |probe, result| [ probe.scope.key, result ] }
      end

      def circuit_generation(record, scope)
        record["routing"].fetch("circuit_generations").find do |entry|
          ProviderHealth.scope_from_h(entry.fetch("scope")) == scope
        end || raise(InvalidMutation, "provider evidence has no enclosing circuit generation")
      end

      def receipt(record)
        return record.receipt.slice("attempt_id", "receipt_version", "terminal_lease_version").freeze if
          record.state == "terminal"
        {
          "attempt_id" => record.attempt_id, "receipt_version" => 1,
          "terminal_lease_version" => record.lease_version
        }.freeze
      end
    end
  end
end
