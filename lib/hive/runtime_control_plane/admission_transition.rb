require "digest"
require "hive/attempts/record"
require "hive/runtime_control_plane"
require "hive/runtime_control_plane/dispatch_repository"

module Hive
  module RuntimeControlPlane
    # The sole cross-domain write boundary for dispatch admission. Its short
    # immediate transaction revalidates task identity and live capacity before
    # inserting an attempt. Provider eligibility has no retained state.
    class AdmissionTransition
      def initialize(repository:)
        @repository = repository
        @database = repository.database
      end

      def call(attributes:, source_fingerprint:, admission:, limits:,
               failure_cohort_probe:, route_decision:)
        record = nil
        @database.transaction do |db|
          subject = attributes[:subject] || Attempts::Record.task_stage_subject(
            task_id: attributes[:task_id], task_slug: attributes[:task_slug],
            intended_stage: attributes[:intended_stage]
          )
          decision = validate_decision!(route_decision)
          routing = decision ? explicit_routing(decision.route) :
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
            @repository.admission_row(
              record, task_id: task_id, project_id: project_id,
              source_fingerprint: source_fingerprint
            )
          )
          @repository.admission_claim_cohort_in(db, record, failure_cohort_probe)
          db[:dispatch_requests].where(request_id: record["request_id"]).update(
            state: "admitted", claim_attempt_id: record.attempt_id,
            updated_at: record["accepted_at"], revision: Sequel[:revision] + 1
          ) if record["request_id"]
        end
        record
      rescue Sequel::UniqueConstraintViolation => error
        raise Attempts::RepositoryError, "attempt admission conflicted: #{error.message}"
      end

      private

      def validate_decision!(decision)
        return nil unless decision
        unless decision.selected?
          raise Attempts::RepositoryError, "provider routing decision is not selectable"
        end

        decision
      end

      def explicit_routing(route)
        {
          "mode" => "explicit",
          "route" => {
            "route_id" => route.id,
            "provider_account_id" => route.account,
            "adapter" => route.adapter,
            "launch_binding_id" => route.launch_binding,
            "model" => route.model,
            "effort" => route.effort,
            "billing_route" => route.billing_route,
            "billing_evidence_source" => route.billing_evidence_source
          }
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
            task_slug: record["task_slug"], task_generation: record.task_generation,
            intended_stage: record["intended_stage"], state: "claimed", priority: 0,
            idempotency_key: request_id, claim_owner: "admission",
            claim_attempt_id: record.attempt_id,
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
          task_slug: record["task_slug"], task_generation: record.task_generation,
          intended_stage: record["intended_stage"], claim_attempt_id: record.attempt_id,
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

      def validate_provider_capacity_in(db, decision)
        candidate = decision.candidates.find do |entry|
          entry.eligible? && entry.route.id == decision.route.id
        end
        unless candidate&.max_concurrency
          raise Attempts::RepositoryError, "provider capacity observation is unavailable"
        end

        reserved = db[:attempts].where(
          provider_account_id: decision.route.account,
          state: %w[launching running]
        ).count
        return if reserved < candidate.max_concurrency

        raise Attempts::CapacityExceeded, "provider account capacity exhausted"
      end
    end
  end
end
