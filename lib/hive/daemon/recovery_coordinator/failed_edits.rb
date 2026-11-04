module Hive
  module Daemon
    module FailedEdits
      FAILED_EDIT_PARK_REMEDIATION =
        "edits do not release this park; use the current workflow.retry action".freeze

      # Observation is also the restart entry point. No marker is cleared and
      # no retry is inferred from complete answers or an mtime comparison.
      def request_failed_edit(row:, requestor:, observation_token: nil, now: Time.now.utc)
        task = resolve_task_for(row)
        Hive::Lock.with_task_lock(task.folder, "operation" => "failed_edit_recovery") do
          locked = resolve_task_for(row)
          unless same_task_identity?(task, locked) && observed_task_identity_matches?(row, locked)
            return receipt("blocked", owner: "operator", reason: "task_identity_conflict")
          end
          if locked.id.to_s.empty?
            return receipt("blocked", owner: "hive", reason: "missing_task_id",
              remediation: missing_task_id_remediation(next_step: "retry from fresh status"))
          end
          if task_history_invalid_row?(row)
            return receipt("blocked", owner: "operator", reason: Hive::TaskProjection::INVALID_HISTORY_REASON)
          end
          generation = current_generation(locked, project: value(row, :project), intended_stage: value(row, :stage))
          binding = Hive::Attempts::FailedEdit.task_binding(generation)
          existing = request_queue.find_failed_edit_recovery(project: value(row, :project),
            slug: value(row, :slug), task_binding: binding)
          marker = Hive::Markers.current(locked.state_file)
          if observation_token && !secure_compare(observation_token,
              failed_edit_observation_token(row, locked, marker, existing))
            return receipt("blocked", owner: "operator", reason: "stale_observation",
              remediation: "refresh status and use the current workflow.retry action")
          end
          records = failed_edit_records(locked, value(row, :stage), project: value(row, :project))
          if failed_edit_live_owner?(locked, records)
            return receipt("running", owner: "agent", reason: "existing_live")
          end
          if existing && %w[admitted cleared].include?(existing.recovery["phase"])
            unless failed_edit_source_current?(existing, locked, records: records)
              request_queue.remove(existing.request_id)
              return nil
            end
            existing = rebind_failed_edit(existing, generation, now: now)
            if self.class::OPERATOR_REQUESTORS.include?(requestor.to_s)
              safe, reason = @safety.call(safety_observation(row, locked, marker))
              return block_request(existing, "safety_blocked", owner: "operator", remediation: reason) unless safe == true
              existing = expedite_operator_recovery(existing, now: now, requestor: "action")
            end
            return receipt_for_request(existing, now: now)
          end
          evidence = Hive::Attempts::FailedEdit.observe(task: locked, generation: generation, records: records)
          return nil unless evidence
          return receipt_for_request(existing, now: now) if existing &&
            existing.recovery["source_binding"] == evidence["source_binding"]
          safe, reason = @safety.call(safety_observation(row, locked, marker))
          return receipt("blocked", owner: "operator", reason: "safety_blocked", remediation: reason) unless safe == true
          attrs = evidence.slice("reason", "provider", "status_code", "message").merge(
            "attempt_id" => evidence.dig("source_binding", "attempt_id"))
          count = retry_count_for_failure(row, attrs, variant: "failed_edit")
          history = failure_evidence_for(row, retry_count: count, marker_attrs: attrs, variant: "failed_edit")
          recovery = evidence.merge(
            "variant" => "failed_edit", "phase" => "admitted",
            "observed_marker_generation" => nil, "expected_marker_attrs" => {},
            "canonical_task_folder" => canonical_path(locked.folder),
            "expected_post_clear_progress_fingerprint" => generation.progress_token,
            "dispatch_generation" => generation.task_generation,
            "failure_origin" => evidence["reason"],
            "next_eligible_at" => (Time.iso8601(evidence["failed_at"]) + retry_delay_sec(count)).utc.iso8601(6),
            "owner" => history["deterministic"] ? "operator" : "scheduler",
            "blocked_reason" => history["deterministic"] ? "deterministic_failure" : nil,
            "blocked_remediation" => history["deterministic"] ? FAILED_EDIT_PARK_REMEDIATION : nil,
            "retry_count" => count + 1, "failure_fingerprint" => history["fingerprint"],
            "identical_failure_count" => history["count"], "failure_attempt_history" => history["attempts"],
            "runtime_digest" => @runtime_digest, "provider_hint" => provider_hint(row),
            "policy_digest" => nil, "source_receipt" => nil, "admission_observation" => nil
          )
          id = "failed-edit-" + Digest::SHA256.hexdigest(JSON.generate(evidence["source_binding"]))[0, 48]
          request_queue.write_request!(project: value(row, :project), slug: value(row, :slug),
            argv: markerless_retry_argv(row), requestor: requestor, trigger: "recovery/failed_edit",
            request_id: id, task_id: locked.id, expected_stage: value(row, :stage),
            task_generation: generation.task_generation, recovery: recovery, now: now)
          request_queue.remove_terminal_recoveries(project: value(row, :project), slug: value(row, :slug),
            expected_stage: value(row, :stage), variant: "failed_edit", except_request_id: id)
          receipt_for_request(request_queue.fetch(id), now: now)
        end
      rescue Hive::ConcurrentRunError
        receipt("running", owner: "agent", reason: "existing_live")
      rescue Hive::Error, SystemCallError, IOError, ArgumentError => error
        receipt("unavailable", owner: "hive", reason: "recovery_unavailable", remediation: error.message)
      end

      private

      def failed_edit_recovery?(recovery) = recovery["variant"] == "failed_edit"

      def failed_edit_source_current?(request, task, records: nil)
        recovery = request.recovery
        marker = Hive::Markers.current(task.state_file)
        return false unless marker.name == :waiting || marker.none?
        records ||= failed_edit_records(task, request.expected_stage, project: request.project)
        return false if failed_edit_live_owner?(task, records)
        source = records.find { |record| record.attempt_id == recovery.dig("source_binding", "attempt_id") }
        source ||= attempts_store.fetch(recovery.dig("source_binding", "attempt_id"))
        return false unless source && Hive::Attempts::FailedEdit.valid_source?(source, recovery)
        !records.any? do |record|
          Hive::Attempts::FailedEdit.accepted?(record) &&
            record.receipt.dig("final_checkpoint", "edit_resume_source_binding") == recovery["source_binding"]
        end
      end

      def failed_edit_records(task, stage, project:)
        records = attempts_store.task_stage_records(task_id: task.id, intended_stage: stage)
        if request_queue.respond_to?(:supervised_edit_records)
          records += request_queue.supervised_edit_records(project: project, slug: task.slug,
            task_id: task.id, intended_stage: stage)
        end
        records
      end

      def failed_edit_live_owner?(task, records)
        records.any?(&:live?) || (attempts_store.respond_to?(:live_attempt_for) &&
          attempts_store.live_attempt_for(task_id: task.id)&.live?)
      end

      def rebind_failed_edit(request, generation, now:)
        binding = Hive::Attempts::FailedEdit.input_binding(generation)
        return request if request.recovery["input_binding"] == binding
        recovery = request.recovery.merge("input_binding" => binding,
          "dispatch_generation" => generation.task_generation,
          "expected_post_clear_progress_fingerprint" => generation.progress_token)
        request_queue.replace_failed_edit!(request, recovery: recovery,
          task_generation: generation.task_generation, now: now)
      end

      def failed_edit_token(base, recovery)
        Digest::SHA256.hexdigest(JSON.generate([ base, recovery.slice(
          "request_id", "source_binding", "input_binding", "reason", "next_eligible_at") ]))
      end

      def failed_edit_observation_token(row, task, marker, request)
        failed_edit_token(locked_observation_token(row, task, marker), request ? receipt_for_request(request).to_h : {})
      end
    end
  end
end
