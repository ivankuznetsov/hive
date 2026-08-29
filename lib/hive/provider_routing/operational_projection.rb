require "time"
require "hive/attempts/capacity_snapshot"
require "hive/attempts/repository"
require "hive/provider_health"
require "hive/provider_routing"

module Hive
  module ProviderRouting
    # One sanitized operator projection over the durable routing decision
    # cells, attempt-derived account capacity, and authoritative scoped health
    # journals. It never selects a route or mutates task/recovery ownership.
    class OperationalProjection
      SCHEMA = "hive-provider-routing-operational".freeze
      SCHEMA_VERSION = 1
      DECISION_LIMIT = 100

      def initialize(accounts:, health_store: nil, health_store_factory: nil,
                     attempt_store: nil, attempt_store_factory: nil,
                     now: Time.now.utc)
        @accounts = normalize_accounts(accounts)
        @health_store = health_store
        @health_store_factory = health_store_factory || -> { Hive::ProviderHealth.open }
        @attempt_store = attempt_store
        @attempt_store_factory = attempt_store_factory || -> { Hive::Attempts::Repository.open_default }
        @now = now.utc
      end

      def to_h
        return empty_projection if @accounts.empty?

        scan, attempt_issue = attempt_scan
        capacity = capacity_projection(scan)
        decision_rows, decision_issue = decision_projection(scan)
        account_rows = @accounts.values.sort_by(&:id).map do |account|
          account_projection(account, capacity.fetch(account.id))
        end
        issues = [ attempt_issue, decision_issue ].compact
        issues.concat(health_issues(account_rows))
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "generated_at" => @now.iso8601(6),
          "status" => issues.empty? ? "available" : "degraded",
          "issues" => issues.uniq.sort,
          "accounts" => account_rows,
          "decisions" => decision_rows
        }
      end

      private

      def empty_projection
        {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "generated_at" => @now.iso8601(6),
          "status" => "not_configured",
          "issues" => [],
          "accounts" => [],
          "decisions" => []
        }
      end

      def normalize_accounts(accounts)
        unless accounts.is_a?(Hash) && accounts.values.all? { |entry| entry.is_a?(Account) }
          raise Hive::ConfigError, "provider routing inspection requires normalized provider accounts"
        end

        accounts.to_h { |key, value| [ key.to_s, value ] }.freeze
      end

      def attempt_scan
        scan = attempt_store.scan
        issue = scan.invalid_records.empty? ? nil : "attempt_storage_invalid"
        [ scan, issue ]
      rescue Hive::Attempts::RepositoryError, Hive::ConfigError, SystemCallError, IOError
        [ Hive::Attempts::Scan.new(records: [].freeze, invalid_records: [].freeze),
          "attempt_storage_unavailable" ]
      end

      def capacity_projection(scan)
        reserved = begin
          snapshot = Hive::Attempts::CapacitySnapshot.build(
            store: attempt_store, scan: scan, now: @now
          )
          snapshot.reserved_attempt_ids.to_h { |attempt_id| [ attempt_id, true ] }
        rescue Hive::Attempts::RepositoryError
          scan.records.select(&:live?).to_h { |record| [ record.attempt_id, true ] }
        end
        counts = @accounts.keys.to_h { |account_id| [ account_id, 0 ] }
        defaults = @accounts.values.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |account, by_adapter|
          by_adapter[account.adapter] << account.id if account.launch_binding == "default"
        end
        scan.records.each do |record|
          next unless reserved[record.attempt_id]

          account_id = if record.explicit_routing?
            record["routing"].dig("route", "provider_account_id")
          else
            candidates = defaults[record["provider"]]
            candidates.one? ? candidates.first : nil
          end
          counts[account_id] += 1 if counts.key?(account_id)
        end
        counts
      end

      def decision_projection(_scan)
        route_ids = @accounts.values.flat_map do |account|
          account.models.map { |model| "#{account.id}/#{model}" }
        end
        # The attempt repository returns an immutable snapshot. Filtering belongs to
        # this read-only projection, so never mutate the durable reader's
        # array in place.
        entries = attempt_store.routing_decisions(limit: DECISION_LIMIT).select do |entry|
          decision = entry.fetch("decision")
          selected = decision["selected_route"]
          selected_id = selected.is_a?(Hash) ? selected["route_id"] : selected
          candidate_ids = Array(decision["candidates"]).map { |candidate| candidate["route_id"] }
          route_ids.include?(selected_id) || !(candidate_ids & route_ids).empty?
        end
        rows = entries.map do |entry|
          subject = entry.fetch("subject")
          {
            "identity" => {
              "project" => entry.fetch("project"),
              "attempt_id" => entry.fetch("attempt_id"),
              "task_id" => subject["task_id"],
              "task_slug" => subject["task_slug"],
              "intended_stage" => subject["intended_stage"],
              "subject_kind" => subject["kind"]
            },
            "decision" => entry.fetch("decision")
          }
        end
        [ rows, nil ]
      rescue Hive::Attempts::RepositoryError, Hive::ConfigError, SystemCallError, IOError
        [ [], "routing_decisions_unavailable" ]
      end

      def account_projection(account, observed)
        provider_scope = Hive::ProviderHealth::Scope.provider_account(account_id: account.id)
        model_scopes = account.models.sort.map do |model|
          Hive::ProviderHealth::Scope.model(account_id: account.id, model_id: model)
        end
        inspections = health_store.inspect_scopes([ provider_scope, *model_scopes ], now: @now)
        {
          "provider_account_id" => account.id,
          "adapter" => account.adapter,
          "launch_binding_id" => account.launch_binding,
          "capacity" => {
            "observed" => observed,
            "max" => account.max_concurrent
          },
          "circuit" => inspection_projection(inspections.first),
          "models" => account.models.sort.each_with_index.map do |model, index|
            {
              "model" => model,
              "route_id" => "#{account.id}/#{model}",
              "circuit" => inspection_projection(inspections.fetch(index + 1))
            }
          end
        }
      rescue Hive::ProviderHealth::Error, Hive::ConfigError, SystemCallError, IOError
        unavailable_account_projection(account, observed)
      end

      def unavailable_account_projection(account, observed)
        {
          "provider_account_id" => account.id,
          "adapter" => account.adapter,
          "launch_binding_id" => account.launch_binding,
          "capacity" => { "observed" => observed, "max" => account.max_concurrent },
          "circuit" => unavailable_scope(
            Hive::ProviderHealth::Scope.provider_account(account_id: account.id)
          ),
          "models" => account.models.sort.map do |model|
            scope = Hive::ProviderHealth::Scope.model(account_id: account.id, model_id: model)
            { "model" => model, "route_id" => "#{account.id}/#{model}", "circuit" => unavailable_scope(scope) }
          end
        }
      end

      def inspection_projection(inspection)
        return unavailable_inspection_projection(inspection) unless inspection.available?

        circuit = inspection.circuit
        evidence = circuit.evidence
        Hive::ProviderHealth.circuit_observation(inspection, now: @now).merge(
          "automatic_state" => circuit.automatic_state,
          "reason" => circuit_reason(circuit),
          "manual_block" => circuit.manual_block,
          "evidence" => evidence && {
            "failure_class" => evidence["failure_class"],
            "provenance" => evidence["provenance"],
            "fingerprint" => evidence["fingerprint"],
            "source_reference" => evidence["source_reference"]
          },
          "corruption_token" => nil,
          "artifact_reference" => nil
        )
      end

      def unavailable_inspection_projection(inspection)
        Hive::ProviderHealth.circuit_observation(inspection, now: @now).merge(
          "automatic_state" => nil,
          "reason" => inspection.unavailable_reason || "health_state_unavailable",
          "manual_block" => nil,
          "evidence" => nil,
          "corruption_token" => inspection.corruption_token&.to_h,
          "artifact_reference" => inspection.artifact_reference
        )
      end

      def unavailable_scope(scope)
        {
          "status" => "unavailable",
          "scope" => scope.to_h,
          "state" => "health_state_unavailable",
          "automatic_state" => nil,
          "reason" => "health_state_unavailable",
          "generation" => 0,
          "journal_epoch" => 0,
          "eligible_at" => nil,
          "manual_block" => nil,
          "probe_owner" => nil,
          "evidence" => nil,
          "corruption_token" => nil,
          "artifact_reference" => nil
        }
      end

      def circuit_reason(circuit)
        return "manual_block" if circuit.blocked?
        return "half_open_probe_owned" if circuit.probe_owned?
        return circuit.evidence["failure_class"] if circuit.automatic_state == "open"

        nil
      end

      def health_issues(accounts)
        accounts.flat_map do |account|
          [ account.fetch("circuit"), *account.fetch("models").map { |model| model.fetch("circuit") } ]
        end.filter_map do |circuit|
          "health_state_unavailable" unless circuit.fetch("status") == "available"
        end
      end

      def health_store
        @health_store ||= @health_store_factory.call
      end

      def attempt_store
        @attempt_store ||= @attempt_store_factory.call
      end
    end
  end
end
