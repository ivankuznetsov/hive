require "date"
require "digest"
require "time"
require "hive/attempts/record"
require "hive/provider_health/repository"
require "hive/provider_routing/policy_repository"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/dispatch_repository"

module Hive
  module RuntimeControlPlane
    # The sole cross-domain write boundary for dispatch admission. Its short
    # immediate transaction performs only bounded SQLite work.
    class AdmissionTransition
      def initialize(repository:, health_repository: nil)
        @repository = repository
        @database = repository.database
        @health = health_repository || ProviderHealth::Repository.new(database: @database)
        @policies = ProviderRouting::PolicyRepository.new(store: repository)
      end

      def call(attributes:, source_fingerprint:, admission:, limits:,
               failure_cohort_probe:, routing_policy:, route_decision:)
        record = nil
        @database.transaction do |db|
          subject = attributes[:subject] || Attempts::Record.task_stage_subject(
            task_id: attributes[:task_id], task_slug: attributes[:task_slug],
            intended_stage: attributes[:intended_stage]
          )
          frozen_policy = @policies.fetch_or_store_in(
            db, ownership_generation: attributes[:ownership_generation] || attributes[:task_generation],
            subject: subject, policy: routing_policy
          )
          decision = validate_decision!(route_decision, frozen_policy)
          @health.validate_route_in(db, decision, now: attributes.fetch(:now)) if decision
          bindings = predicted_probe_bindings(decision, attributes)
          routing = decision ? explicit_routing(decision, bindings) :
            attributes.fetch(:routing, { "mode" => "legacy" })
          record = Attempts::Record.launching(**attributes.merge(subject: subject, routing: routing))
          task_id, project_id = @repository.admission_subject_in(
            db, record, source_fingerprint: source_fingerprint
          )
          @repository.admission_validate_subject_in(
            db, task_id: task_id, source_fingerprint: source_fingerprint,
            generation: record.task_input_epoch
          )
          claim_request!(
            db, record, task_id, project_id,
            source_fingerprint: source_fingerprint
          )
          @repository.admission_validate_capacity_in(db, record, limits) if limits
          validate_provider_capacity_in(db, decision) if decision
          db[:attempts].insert(
            @repository.admission_row(record, task_id: task_id, source_fingerprint: source_fingerprint)
          )
          if decision
            claimed = @health.claim_probe_bindings_in(
              db, requirements: decision.probe_requirements,
              attempt_id: record.attempt_id,
              task_generation: record.task_generation,
              ownership_fence: record.ownership_generation,
              now: attributes.fetch(:now)
            )
            raise Attempts::RepositoryError, "provider probe binding changed" unless
              claimed.map(&:to_h) == bindings.map(&:to_h)
          end
          persist_accounting(db, record, admission)
          persist_relationship(db, record)
          @repository.admission_claim_cohort_in(db, record, failure_cohort_probe)
          persist_decision(db, record, decision) if decision
          db[:dispatch_requests].where(request_id: record["request_id"]).update(
            state: "admitted", routing_policy_digest: decision&.policy_digest,
            updated_at: record["accepted_at"], revision: Sequel[:revision] + 1
          ) if record["request_id"]
        end
        record
      rescue ProviderHealth::StaleGeneration
        raise
      rescue Sequel::UniqueConstraintViolation => error
        raise Attempts::RepositoryError, "attempt admission conflicted: #{error.message}"
      end

      private

      def validate_decision!(decision, policy)
        return nil if policy.legacy?
        unless decision&.selected? && decision.policy_digest == policy.digest
          raise Attempts::RepositoryError, "provider routing decision is stale"
        end
        decision
      end

      def predicted_probe_bindings(decision, attributes)
        return [] unless decision
        decision.probe_requirements.map do |requirement|
          ProviderHealth::ProbeBinding.new(
            scope: requirement.scope,
            journal_epoch: requirement.journal_epoch,
            observed_generation: requirement.observed_generation,
            claim_generation: requirement.observed_generation + 1,
            attempt_id: attributes.fetch(:attempt_id),
            task_generation: attributes.fetch(:task_generation),
            ownership_fence: attributes[:ownership_generation] || attributes.fetch(:task_generation)
          )
        end
      end

      def explicit_routing(decision, bindings)
        route = decision.route
        {
          "mode" => "explicit", "policy_digest" => decision.policy_digest,
          "decision" => decision.to_record_h,
          "route" => {
            "route_id" => route.id, "provider_account_id" => route.account,
            "adapter" => route.adapter, "launch_binding_id" => route.launch_binding,
            "model" => route.model, "effort" => route.effort,
            "billing_route" => route.billing_route,
            "billing_evidence_source" => route.billing_evidence_source
          },
          "circuit_generations" => decision.circuit_generations,
          "probe_bindings" => bindings.map(&:to_h)
        }
      end

      def claim_request!(db, record, task_id, project_id, source_fingerprint:)
        request_id = record["request_id"]
        return unless request_id
        row = db[:dispatch_requests].where(request_id: request_id).first
        unless row
          db[:dispatch_requests].insert(
            request_id: request_id, project_id: project_id, task_id: task_id,
            subject_kind: record.subject_kind,
            subject_key: Digest::SHA256.hexdigest(Codec.dump_json(record.subject)),
            task_generation: record.task_generation,
            intended_stage: record["intended_stage"], state: "claimed", priority: 0,
            idempotency_key: request_id, claim_owner: "admission",
            claimed_at: record["accepted_at"], source_fingerprint: source_fingerprint.to_s,
            payload_json: Codec.dump_json(admission_request_payload(record)),
            created_at: record["accepted_at"], updated_at: record["accepted_at"],
            revision: 0
          )
          return
        end
        unless %w[queued claimed].include?(row.fetch(:state)) && row.fetch(:project_id) == project_id
          raise Attempts::RepositoryError, "dispatch request is not claimable"
        end
        payload = Codec.load_json(row.fetch(:payload_json))
        bound_generation = payload["task_generation"]
        bound_task = payload["task_id"]
        predecessor_generation =
          payload.dig("recovery", "source_receipt", "task_generation") ||
          payload.dig("recovery", "expected_marker_attrs", "task_generation")
        generation_matches = bound_generation.to_s.empty? ||
          [ bound_generation, predecessor_generation ].compact.map(&:to_s)
            .include?(record.task_generation)
        if !generation_matches ||
           (!bound_task.to_s.empty? && bound_task.to_s != record["task_id"].to_s)
          raise Attempts::RepositoryError, "dispatch request source binding changed"
        end
        changed = db[:dispatch_requests].where(
          request_id: request_id, revision: row.fetch(:revision), state: row.fetch(:state)
        ).update(
          task_id: task_id, subject_kind: record.subject_kind,
          subject_key: Digest::SHA256.hexdigest(Codec.dump_json(record.subject)),
          task_generation: record.task_generation, intended_stage: record["intended_stage"],
          state: "claimed", claim_owner: "admission", claimed_at: record["accepted_at"],
          source_fingerprint: source_fingerprint.to_s, updated_at: record["accepted_at"],
          revision: Sequel[:revision] + 1
        )
        raise Attempts::CompareAndSwapFailed, "dispatch request claim raced" unless changed == 1
      end

      def admission_request_payload(record)
        {
          "schema" => DispatchRepository::SCHEMA,
          "schema_version" => DispatchRepository::SCHEMA_VERSION,
          "request_id" => record["request_id"], "created_at" => record["accepted_at"],
          "project" => record["project"], "slug" => record["task_slug"],
          "argv" => record["worker_argv"], "requestor" => "daemon",
          "chat_id" => nil, "update_id" => nil, "trigger" => "attempt-admission",
          "task_generation" => record.task_generation,
          "predecessor_attempt_id" => record["predecessor_attempt_id"],
          "inherited_outputs" => record["inherited_outputs"],
          "task_id" => record["task_id"], "expected_stage" => record["intended_stage"],
          "expected_marker_name" => nil, "expected_marker_id" => nil,
          "recovery" => nil, "remaining_argvs" => []
        }
      end

      def persist_accounting(db, record, admission)
        db[:attempt_accounting].insert(
          attempt_id: record.attempt_id,
          provider_account_id: record["routing"].dig("route", "provider_account_id"),
          retry_charge: record["retry_charge"], refunded: 0,
          reservation_json: Codec.dump_json(
            @repository.admission_reservation(record, admission)
          ),
          billing_json: Codec.dump_json("refunded" => false),
          updated_at: record["accepted_at"]
        )
        db[:capacity_reservations].insert(
          reservation_id: "attempt:#{record.attempt_id}", attempt_id: record.attempt_id,
          scope_kind: "host", scope_key: "global", units: 1, state: "reserved",
          created_at: record["accepted_at"]
        )
      end

      def validate_provider_capacity_in(db, decision)
        candidate = decision.candidates.find do |entry|
          entry.eligible? && entry.route.id == decision.route.id
        end
        unless candidate&.max_concurrency
          raise Attempts::RepositoryError, "provider capacity observation is unavailable"
        end

        reserved = db[:capacity_reservations]
          .join(:attempt_accounting, attempt_id: :attempt_id)
          .where(
            Sequel[:capacity_reservations][:state] => "reserved",
            Sequel[:attempt_accounting][:provider_account_id] => decision.route.account
          )
          .sum(Sequel[:capacity_reservations][:units]).to_i
        return if reserved < candidate.max_concurrency

        raise Attempts::CapacityExceeded, "provider account capacity exhausted"
      end

      def persist_relationship(db, record)
        return unless record["predecessor_attempt_id"]
        db[:attempt_relationships].insert(
          attempt_id: record.attempt_id,
          related_attempt_id: record["predecessor_attempt_id"],
          kind: "successor", created_at: record["accepted_at"]
        )
      end

      def persist_decision(db, record, decision)
        subject_json = Codec.dump_json(record.subject)
        key = Digest::SHA256.hexdigest([ record.task_generation, subject_json ].join("\0"))
        db[:attempt_routing_decisions].insert_conflict(
          target: :decision_key,
          update: {
            attempt_id: record.attempt_id,
            decision_id: decision.decision_id,
            decision_json: Codec.dump_json(decision.to_h),
            decided_at: decision.decided_at, updated_at: record["accepted_at"]
          }
        ).insert(
          decision_key: key, task_generation: record.task_generation,
          subject_json: subject_json, project_name: record["project"],
          attempt_id: record.attempt_id, decision_id: decision.decision_id,
          decision_json: Codec.dump_json(decision.to_h),
          decided_at: decision.decided_at, updated_at: record["accepted_at"]
        )
      end
    end
  end
end
