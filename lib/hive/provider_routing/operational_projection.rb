require "time"
require "hive/attempts/capacity_snapshot"
require "hive/provider_health"
require "hive/provider_routing"

module Hive
  module ProviderRouting
    class OperationalProjection
      DECISION_LIMIT = 100

      def initialize(accounts:, health_store: nil, health_store_factory: nil,
                     attempt_store: nil, attempt_store_factory: nil, now: Time.now.utc)
        unless accounts.is_a?(Hash) && accounts.values.all? { |value| value.is_a?(Account) }
          raise Hive::ConfigError, "provider routing inspection requires normalized provider accounts"
        end
        @accounts = accounts.transform_keys(&:to_s).freeze
        @health_store = health_store
        @health_factory = health_store_factory || -> { Hive::ProviderHealth.open }
        @attempt_store = attempt_store
        @attempt_factory = attempt_store_factory || -> { Hive::Attempts::Repository.open_default }
        @now = now.utc
      end

      def to_h
        return envelope("not_configured", [], [], []) if @accounts.empty?

        scan, attempt_issue = attempt_scan
        capacity = capacity(scan)
        decision_rows, decision_issue = decision_projection
        accounts = @accounts.values.sort_by(&:id).map { |account| account_row(account, capacity[account.id]) }
        issues = [ attempt_issue, decision_issue ].compact
        issues << "health_state_unavailable" if accounts.any? do |account|
          [ account["circuit"], *account["models"].map { |model| model["circuit"] } ]
            .any? { |circuit| circuit["status"] != "available" }
        end
        envelope(issues.empty? ? "available" : "degraded", issues.uniq.sort, accounts, decision_rows)
      end

      private

      def envelope(status, issues, accounts, decisions)
        {
          "schema" => "hive-provider-routing-operational", "schema_version" => 1,
          "generated_at" => @now.iso8601(6), "status" => status,
          "issues" => issues, "accounts" => accounts, "decisions" => decisions
        }
      end

      def attempt_scan
        [ attempts.active_attempts, nil ]
      rescue Hive::Attempts::RepositoryError, Hive::ConfigError, SystemCallError, IOError
        [ [], "attempt_storage_unavailable" ]
      end

      def capacity(records)
        snapshot = Hive::Attempts::CapacitySnapshot.build(store: attempts, now: @now)
        capacity_from(records, snapshot.reserved_attempt_ids)
      rescue Hive::Attempts::RepositoryError
        capacity_from(records, records.select(&:live?).map(&:attempt_id))
      end

      def capacity_from(records, reserved_attempt_ids)
        Hive::Attempts::CapacitySnapshot.provider_account_capacity(
          accounts: @accounts, records: records, reserved_attempt_ids: reserved_attempt_ids
        ).transform_values { |value| value.fetch("observed") }
      end

      def decision_projection
        route_ids = @accounts.values.flat_map { |account| account.models.map { |model| "#{account.id}/#{model}" } }
        rows = attempts.routing_decisions(limit: DECISION_LIMIT).filter_map do |entry|
          decision = entry.fetch("decision")
          selected = decision["selected_route"]
          selected = selected["route_id"] if selected.is_a?(Hash)
          candidates = Array(decision["candidates"]).map { |candidate| candidate["route_id"] }
          next unless route_ids.include?(selected) || !(candidates & route_ids).empty?
          subject = entry.fetch("subject")
          {
            "identity" => {
              "project" => entry.fetch("project"), "attempt_id" => entry.fetch("attempt_id"),
              "task_id" => subject["task_id"], "task_slug" => subject["task_slug"],
              "intended_stage" => subject["intended_stage"], "subject_kind" => subject["kind"]
            },
            "decision" => decision
          }
        end
        [ rows, nil ]
      rescue Hive::Attempts::RepositoryError, Hive::ConfigError, SystemCallError, IOError
        [ [], "routing_decisions_unavailable" ]
      end

      def account_row(account, observed)
        scopes = [
          Hive::ProviderHealth::Scope.provider_account(account_id: account.id),
          *account.models.sort.map do |model|
            Hive::ProviderHealth::Scope.model(account_id: account.id, model_id: model)
          end
        ]
        circuits = begin
          health.inspect_scopes(scopes, now: @now).map { |inspection| circuit(inspection) }
        rescue Hive::ProviderHealth::Error, Hive::ConfigError, SystemCallError, IOError
          scopes.map { |scope| unavailable(scope) }
        end
        {
          "provider_account_id" => account.id, "adapter" => account.adapter,
          "launch_binding_id" => account.launch_binding,
          "capacity" => { "observed" => observed, "max" => account.max_concurrent },
          "circuit" => circuits.first,
          "models" => account.models.sort.each_with_index.map do |model, index|
            { "model" => model, "route_id" => "#{account.id}/#{model}", "circuit" => circuits[index + 1] }
          end
        }
      end

      def circuit(inspection)
        return unavailable(inspection.scope, inspection) unless inspection.available?
        value = inspection.circuit
        evidence = value.evidence
        Hive::ProviderHealth.circuit_observation(inspection, now: @now).merge(
          "automatic_state" => value.automatic_state,
          "reason" => value.blocked? ? "manual_block" :
            (value.probe_owned? ? "half_open_probe_owned" : evidence&.fetch("failure_class", nil)),
          "manual_block" => value.manual_block,
          "evidence" => evidence&.slice("failure_class", "provenance", "fingerprint", "source_reference"),
          "corruption_token" => nil, "artifact_reference" => nil
        )
      end

      def unavailable(scope, inspection = nil)
        {
          "status" => "unavailable", "scope" => scope.to_h,
          "state" => "health_state_unavailable", "automatic_state" => nil,
          "reason" => inspection&.unavailable_reason || "health_state_unavailable",
          "generation" => inspection&.generation || 0,
          "journal_epoch" => inspection&.journal_epoch || 0,
          "eligible_at" => nil, "manual_block" => nil, "probe_owner" => nil,
          "evidence" => nil, "corruption_token" => inspection&.corruption_token&.to_h,
          "artifact_reference" => inspection&.artifact_reference
        }
      end

      def health = @health_store ||= @health_factory.call
      def attempts = @attempt_store ||= @attempt_factory.call
    end
  end
end
