Sequel.migration do
  up do
    run "PRAGMA application_id = #{Hive::RuntimeControlPlane::APPLICATION_ID}"

    create_table(:installations) do
      String :installation_id, primary_key: true, null: false
      String :lineage_id, null: false, unique: true
      Integer :activation_epoch, null: false, default: 0
      String :created_at, null: false
      String :activated_at
      check Sequel.lit("activation_epoch >= 0")
    end

    create_table(:projects) do
      String :project_id, primary_key: true, null: false
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      %i[registration_id name observed_path state_root_path].each { |column| String column, null: false }
      String :repository_identity_json
      Integer :active, null: false, default: 1
      String :registered_at, null: false
      String :last_observed_at
      check Sequel.lit("active IN (0, 1)")
      unique [ :installation_id, :registration_id ], name: :projects_registration_uidx
      unique [ :installation_id, :name ], name: :projects_name_uidx
      unique [ :installation_id, :state_root_path ], name: :projects_state_root_uidx
    end

    create_table(:task_subjects) do
      String :task_id, primary_key: true, null: false
      foreign_key :project_id, :projects, type: String, key: :project_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      %i[workflow_id task_slug observed_path].each { |column| String column, null: false }
      String :source_fingerprint
      Integer :generation, null: false, default: 0
      %i[created_at last_observed_at].each { |column| String column, null: false }
      check Sequel.lit("generation >= 0")
      unique [ :project_id, :workflow_id, :task_slug ], name: :task_subjects_alias_uidx
    end

    create_table(:dispatch_requests) do
      String :request_id, primary_key: true, null: false
      foreign_key :project_id, :projects, type: String, key: :project_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  on_delete: :cascade, on_update: :cascade
      %i[subject_kind subject_key task_slug task_generation intended_stage state source_fingerprint].each do |column|
        String column, null: false
      end
      Integer :priority, null: false, default: 0
      %i[
        idempotency_key claim_owner claim_process_identity claim_attempt_id claimed_at due_at
        retain_until result_state result_digest result_available_at result_delivered_at
      ].each { |column| String column }
      Integer :claim_pid
      Integer :recovery_request, null: false, default: 0
      Integer :revision, null: false, default: 0
      String :payload_json, text: true, null: false
      String :result_json, text: true
      %i[created_at updated_at].each { |column| String column, null: false }
      check Sequel.lit("priority >= 0")
      check Sequel.lit("revision >= 0")
      check Sequel.lit("claim_pid IS NULL OR claim_pid > 0")
      check Sequel.lit("recovery_request IN (0, 1)")
      check Sequel.lit("subject_kind IN ('task_stage', 'module_hook')")
      check Sequel.lit(
        "state IN ('queued', 'claimed', 'admitted', 'awaiting_delivery', 'completed', 'cancelled')"
      )
      check Sequel.lit("result_state IS NULL OR result_state IN ('pending', 'delivered')")
      check Sequel.lit(
        "(result_state IS NULL AND result_json IS NULL AND result_digest IS NULL AND " \
        "result_available_at IS NULL AND result_delivered_at IS NULL AND retain_until IS NULL) OR " \
        "(result_state = 'pending' AND result_json IS NOT NULL AND length(result_digest) = 64 AND " \
        "result_available_at IS NOT NULL AND result_delivered_at IS NULL AND retain_until IS NOT NULL) OR " \
        "(result_state = 'delivered' AND result_json IS NOT NULL AND length(result_digest) = 64 AND " \
        "result_available_at IS NOT NULL AND result_delivered_at IS NOT NULL AND retain_until IS NOT NULL)"
      )
      index [ :state, :priority, :created_at ], name: :dispatch_requests_ready_idx
      index [ :idempotency_key ], unique: true,
            where: Sequel.lit("idempotency_key IS NOT NULL"),
            name: :dispatch_requests_idempotency_uidx
      index [ :task_id, :subject_key, :task_generation ], unique: true,
            where: Sequel.lit("task_id IS NOT NULL AND state IN ('queued', 'claimed', 'admitted')"),
            name: :dispatch_requests_active_subject_uidx
      index [ :task_id ], name: :dispatch_requests_task_idx
      index [ :project_id, :task_slug, :recovery_request, :created_at ],
            name: :dispatch_requests_recovery_idx
      index [ :recovery_request, :updated_at, :request_id ],
            name: :dispatch_requests_recovery_projection_idx
      index [ :result_available_at, :request_id ],
            where: Sequel.lit("result_state = 'pending'"),
            name: :dispatch_requests_result_ready_idx
      index [ :retain_until, :request_id ],
            where: Sequel.lit("result_state = 'delivered'"),
            name: :dispatch_requests_result_retention_idx
    end

    create_table(:attempts) do
      String :attempt_id, primary_key: true, null: false
      foreign_key :request_id, :dispatch_requests, type: String, key: :request_id,
                  on_delete: :set_null, on_update: :cascade
      foreign_key :project_id, :projects, type: String, key: :project_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  on_delete: :cascade, on_update: :cascade
      %i[subject_kind subject_key task_generation ownership_generation state].each do |column|
        String column, null: false
      end
      %i[outcome provider_account_id started_at heartbeat_at ended_at retain_until].each do |column|
        String column
      end
      Integer :lease_version, null: false, default: 0
      Integer :retry_charge, null: false, default: 0
      Integer :refunded, null: false, default: 0
      %i[admission_workflow admission_stage admission_runtime_digest admission_utc_date].each do |column|
        String column
      end
      %i[
        lost_recovery_phase lost_recovery_cleanup lost_recovery_request_id
        lost_recovery_updated_at
      ].each { |column| String column }
      Integer :lost_recovery_revision
      String :terminal_receipt_json, text: true
      %i[
        terminal_receipt_digest terminal_task_source_fingerprint terminal_publication_created_at
      ].each { |column| String column }
      Integer :publication_journal_acknowledged, null: false, default: 0
      Integer :publication_accounting_acknowledged, null: false, default: 0
      Integer :publication_dispatch_acknowledged, null: false, default: 0
      %i[
        failure_cohort_date failure_cohort_identity_digest failure_cohort_outcome
        failure_cohort_occurred_at
      ].each { |column| String column }
      Integer :failure_cohort_counted, null: false, default: 0
      String :source_fingerprint, null: false
      String :record_json, text: true, null: false
      String :record_digest, null: false
      String :subject_json, text: true, null: false
      %i[project_name task_slug accepted_date].each { |column| String column, null: false }
      %i[created_at accepted_at].each { |column| String column, null: false }
      check Sequel.lit("lease_version >= 0")
      check Sequel.lit("retry_charge >= 0")
      check Sequel.lit("refunded IN (0, 1)")
      check Sequel.lit(
        "publication_journal_acknowledged IN (0, 1) AND " \
        "publication_accounting_acknowledged IN (0, 1) AND " \
        "publication_dispatch_acknowledged IN (0, 1)"
      )
      check Sequel.lit("failure_cohort_counted IN (0, 1)")
      check Sequel.lit("subject_kind IN ('task_stage', 'module_hook')")
      check Sequel.lit(
        "(subject_kind = 'task_stage' AND task_id IS NOT NULL) OR " \
        "(subject_kind = 'module_hook' AND task_id IS NULL)"
      )
      check Sequel.lit("state IN ('launching', 'running', 'terminal', 'lost')")
      check Sequel.lit("outcome IS NULL OR outcome IN ('succeeded', 'failed', 'cancelled')")
      check Sequel.lit("(state = 'terminal' AND outcome IS NOT NULL) OR (state != 'terminal' AND outcome IS NULL)")
      check Sequel.lit(
        "(admission_workflow IS NULL AND admission_stage IS NULL AND " \
        "admission_runtime_digest IS NULL AND admission_utc_date IS NULL) OR " \
        "(admission_workflow = 'patrol_fix' AND admission_stage IS NOT NULL AND " \
        "length(admission_runtime_digest) = 64 AND admission_utc_date IS NOT NULL)"
      )
      check Sequel.lit(
        "(lost_recovery_phase IS NULL AND lost_recovery_cleanup IS NULL AND " \
        "lost_recovery_request_id IS NULL AND lost_recovery_revision IS NULL AND " \
        "lost_recovery_updated_at IS NULL) OR " \
        "(state = 'lost' AND lost_recovery_phase IN ('pending', 'ready', 'complete') AND " \
        "lost_recovery_revision >= 0 AND lost_recovery_updated_at IS NOT NULL AND " \
        "(lost_recovery_phase != 'complete' OR lost_recovery_request_id IS NOT NULL))"
      )
      check Sequel.lit(
        "lost_recovery_cleanup IS NULL OR lost_recovery_cleanup IN " \
        "('absent', 'terminated', 'no_worker', 'identity_mismatch', 'identity_changed', 'still_alive')"
      )
      check Sequel.lit(
        "(terminal_receipt_json IS NULL AND terminal_receipt_digest IS NULL AND " \
        "terminal_task_source_fingerprint IS NULL AND terminal_publication_created_at IS NULL AND " \
        "publication_journal_acknowledged = 0 AND " \
        "publication_accounting_acknowledged = 0 AND publication_dispatch_acknowledged = 0) OR " \
        "(state IN ('terminal', 'lost') AND terminal_receipt_json IS NOT NULL AND " \
        "length(terminal_receipt_digest) = 64 AND terminal_task_source_fingerprint IS NOT NULL AND " \
        "terminal_publication_created_at IS NOT NULL)"
      )
      check Sequel.lit(
        "(failure_cohort_outcome IS NULL AND failure_cohort_date IS NULL AND " \
        "failure_cohort_identity_digest IS NULL AND failure_cohort_occurred_at IS NULL AND " \
        "failure_cohort_counted = 0) OR " \
        "(state IN ('terminal', 'lost') AND failure_cohort_outcome = 'failed' AND " \
        "failure_cohort_date IS NOT NULL AND length(failure_cohort_identity_digest) = 64 AND " \
        "failure_cohort_occurred_at IS NOT NULL AND failure_cohort_counted = 1) OR " \
        "(state IN ('terminal', 'lost') AND failure_cohort_outcome = 'succeeded' AND " \
        "failure_cohort_date IS NOT NULL AND failure_cohort_identity_digest IS NULL AND " \
        "failure_cohort_occurred_at IS NOT NULL AND failure_cohort_counted = 0)"
      )
      index [ :request_id ], unique: true, name: :attempts_request_uidx
      index [ :project_id ], name: :attempts_project_idx
      index [ :task_id, :subject_key, :task_generation ], unique: true,
            where: Sequel.lit("state IN ('launching', 'running')"),
            name: :attempts_active_subject_generation_uidx
      index [ :state, :project_name, :task_slug ], name: :attempts_live_idx
      index [ :provider_account_id, :state ], name: :attempts_provider_live_idx
      index [ :task_id, :task_generation, :ended_at ], name: :attempts_terminal_idx
      index [ :project_name, :accepted_date, :refunded ], name: :attempts_daily_idx
      index [ :lost_recovery_phase, :lost_recovery_updated_at, :attempt_id ],
            where: Sequel.lit("lost_recovery_phase IS NOT NULL"),
            name: :attempts_lost_recovery_idx
      index [ :terminal_publication_created_at, :attempt_id ],
            where: Sequel.lit(
              "terminal_receipt_json IS NOT NULL AND " \
              "(publication_journal_acknowledged = 0 OR " \
              "publication_accounting_acknowledged = 0 OR publication_dispatch_acknowledged = 0)"
            ),
            name: :attempts_publication_pending_idx
      index [ :failure_cohort_date, :failure_cohort_identity_digest, :failure_cohort_counted ],
            where: Sequel.lit("failure_cohort_outcome = 'failed'"),
            name: :attempts_failure_cohort_idx
    end

    create_table(:attempt_failure_cohorts) do
      %i[utc_date identity_digest updated_at].each { |column| String column, null: false }
      String :identity_json, text: true, null: false
      Integer :failure_count, null: false, default: 0
      String :retry_at
      foreign_key :probe_attempt_id, :attempts, type: String, key: :attempt_id,
                  on_delete: :set_null, on_update: :cascade
      String :probe_expires_at
      primary_key [ :utc_date, :identity_digest ]
      check Sequel.lit("failure_count >= 0")
      index [ :probe_attempt_id ], name: :attempt_failure_cohorts_probe_idx
    end

    create_table(:pr_merge_reconciliations) do
      String :reconciliation_id, primary_key: true, null: false
      foreign_key :project_id, :projects, type: String, key: :project_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  on_delete: :set_null, on_update: :cascade
      %i[
        task_generation repository_identity registration_id project_path
        state_root_path host default_branch
      ].each { |column| String column, null: false }
      Integer :pr_number, null: false
      %i[merge_sha retry_not_before hold_reason completed_at].each { |column| String column }
      String :state, null: false
      Integer :retry_failures, null: false, default: 0
      String :remote_state, null: false, default: "unknown"
      %i[architecture_state archive_state].each { |column| String column, null: false, default: "pending" }
      Integer :held, null: false, default: 0
      Integer :revision, null: false, default: 0
      String :observation_json, text: true, null: false
      %i[observed_at updated_at].each { |column| String column, null: false }
      check Sequel.lit("pr_number > 0")
      check Sequel.lit("state IN ('pending', 'merged', 'closed', 'failed')")
      check Sequel.lit("retry_failures >= 0")
      check Sequel.lit("held IN (0, 1)")
      check Sequel.lit("revision >= 0")
      check Sequel.lit("remote_state IN ('unknown', 'open', 'merged', 'closed_unmerged', 'delivered_elsewhere', 'ambiguous')")
      check Sequel.lit("architecture_state IN ('pending', 'accepted', 'deferred', 'failed', 'blocked', 'not_required')")
      check Sequel.lit("archive_state IN ('pending', 'blocked', 'archived', 'failed', 'superseded')")
      index [ :project_id, :repository_identity, :pr_number ],
            name: :pr_merge_reconciliations_pr_idx
      index [ :state, :observed_at ], name: :pr_merge_reconciliations_pending_idx
      index [ :project_id, :archive_state, :retry_not_before, :reconciliation_id ],
            name: :pr_merge_reconciliations_ready_idx
      index [ :task_id ], name: :pr_merge_reconciliations_task_idx
    end

    create_table(:pr_merge_project_state) do
      foreign_key :project_id, :projects, type: String, key: :project_id,
                  primary_key: true, null: false, on_delete: :cascade, on_update: :cascade
      String :cursor
      String :backlog_json, text: true, null: false
      String :updated_at, null: false
    end

    create_table(:task_leases) do
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  primary_key: true, null: false, on_delete: :cascade, on_update: :cascade
      %i[
        holder_kind holder_id holder_process_identity acquired_at expires_at released_at
      ].each { |column| String column }
      Integer :holder_pid
      String :payload_json, text: true, null: false, default: "{}"
      Integer :generation, null: false
      Integer :lease_version, null: false
      String :source_fingerprint, null: false
      check Sequel.lit("generation >= 0")
      check Sequel.lit("lease_version >= 0")
      check Sequel.lit("holder_pid IS NULL OR holder_pid > 0")
      check Sequel.lit("(holder_id IS NULL AND holder_pid IS NULL) OR (holder_id IS NOT NULL AND holder_pid IS NOT NULL)")
      index [ :expires_at ], name: :task_leases_expiry_idx
    end

    create_table(:task_counters) do
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      %i[namespace updated_at].each { |column| String column, null: false }
      Integer :value, null: false
      primary_key [ :installation_id, :namespace ]
      check Sequel.lit("value >= 0")
    end

    create_table(:token_usage) do
      String :id, primary_key: true, null: false
      String :task_id
      String :attempt_id
      String :agent, null: false
      %i[
        session_id model requested_backend requested_model actual_backend actual_model
        project_slug task_slug stage ended_at
      ].each { |column| String column }
      String :started_at, null: false
      Integer :input, null: false, default: 0
      Integer :output, null: false, default: 0
      Integer :cached, null: false, default: 0
      Integer :cache_read
      Integer :cache_write
      Integer :reasoning
      Float :cost
      %i[input_available output_available cached_available].each do |column|
        Integer column, null: false, default: 1
      end
      %i[cache_read_available cache_write_available reasoning_available cost_available].each do |column|
        Integer column, null: false, default: 0
      end
      Integer :task_generation
      %i[source billing_route billing_evidence_source].each { |column| String column }
      Integer :input_includes_cache_read
      Integer :input_includes_cache_write
      Integer :output_includes_reasoning
      check Sequel.lit("input >= 0 AND output >= 0 AND cached >= 0")
      check Sequel.lit("task_generation IS NULL OR task_generation >= 0")
      check Sequel.lit("input_available IN (0, 1) AND output_available IN (0, 1) AND cached_available IN (0, 1)")
      check Sequel.lit("cache_read_available IN (0, 1) AND cache_write_available IN (0, 1) AND reasoning_available IN (0, 1) AND cost_available IN (0, 1)")
      index [ :started_at ], name: :token_usage_started_at_idx
      index [ :project_slug, :started_at ], name: :token_usage_project_idx
      index [ :task_slug, :started_at ], name: :token_usage_task_idx
      index [ :attempt_id, :task_generation ], name: :token_usage_attempt_idx
      index [ :session_id ], unique: true, where: Sequel.lit("session_id IS NOT NULL"),
            name: :token_usage_session_uidx
    end

    create_table(:daemon_runtime) do
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      %i[daemon_kind state observed_at].each { |column| String column, null: false }
      Integer :generation, null: false
      Integer :owner_pid
      String :owner_process_identity
      String :observation_json, text: true, null: false, default: "{}"
      String :expires_at
      primary_key [ :installation_id, :daemon_kind ]
      check Sequel.lit("generation >= 0")
      check Sequel.lit("owner_pid IS NULL OR owner_pid > 0")
      check Sequel.lit("state IN ('starting', 'running', 'stopped', 'unavailable')")
    end

    create_table(:payload_references) do
      String :payload_id, primary_key: true, null: false
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  on_delete: :cascade, on_update: :cascade
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  on_delete: :cascade, on_update: :cascade
      %i[kind relative_path].each { |column| String column, null: false }
      String :sha256
      Integer :bytes
      %i[state created_at].each { |column| String column, null: false }
      String :retain_until
      check Sequel.lit("task_id IS NOT NULL OR attempt_id IS NOT NULL")
      check Sequel.lit("state IN ('open', 'sealed', 'releasable')")
      check Sequel.lit(
        "(state = 'open' AND sha256 IS NULL AND bytes IS NULL) OR " \
        "(state != 'open' AND sha256 IS NOT NULL AND length(sha256) = 64 " \
        "AND bytes IS NOT NULL AND bytes >= 0)"
      )
      check Sequel.lit("(state = 'releasable') = (retain_until IS NOT NULL)")
      index [ :kind, :relative_path ], name: :payload_references_path_idx
      index [ :task_id ], name: :payload_references_task_idx
      index [ :attempt_id ], name: :payload_references_attempt_idx
      index [ :retain_until ], name: :payload_references_retention_idx
    end
  end
end
