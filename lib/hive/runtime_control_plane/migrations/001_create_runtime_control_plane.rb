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
      String :registration_id, null: false
      String :name, null: false
      String :observed_path, null: false
      String :state_root_path, null: false
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
      String :workflow_id, null: false
      String :task_slug, null: false
      String :observed_path, null: false
      String :source_fingerprint
      Integer :generation, null: false, default: 0
      String :created_at, null: false
      String :last_observed_at, null: false
      check Sequel.lit("generation >= 0")
      unique [ :project_id, :workflow_id, :task_slug ], name: :task_subjects_alias_uidx
    end

    create_table(:routing_policies) do
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :policy_key, null: false
      Integer :revision, null: false
      String :policy_digest, null: false
      String :policy_json, text: true, null: false
      String :updated_at, null: false
      primary_key [ :installation_id, :policy_key ]
      check Sequel.lit("revision >= 0")
    end

    create_table(:dispatch_requests) do
      String :request_id, primary_key: true, null: false
      foreign_key :project_id, :projects, type: String, key: :project_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  on_delete: :cascade, on_update: :cascade
      String :subject_kind, null: false
      String :subject_key, null: false
      String :task_generation, null: false
      String :intended_stage, null: false
      String :state, null: false
      Integer :priority, null: false, default: 0
      String :idempotency_key
      String :claim_owner
      Integer :claim_pid
      String :claim_process_identity
      String :claimed_at
      String :due_at
      Integer :revision, null: false, default: 0
      String :source_fingerprint, null: false
      String :routing_policy_digest
      String :payload_json, text: true, null: false
      String :created_at, null: false
      String :updated_at, null: false
      String :retain_until
      check Sequel.lit("priority >= 0")
      check Sequel.lit("revision >= 0")
      check Sequel.lit("claim_pid IS NULL OR claim_pid > 0")
      check Sequel.lit("subject_kind IN ('task_stage', 'module_hook')")
      check Sequel.lit("state IN ('queued', 'claimed', 'admitted', 'completed', 'cancelled')")
      index [ :state, :priority, :created_at ], name: :dispatch_requests_ready_idx
      index [ :idempotency_key ], unique: true,
            where: Sequel.lit("idempotency_key IS NOT NULL"),
            name: :dispatch_requests_idempotency_uidx
      index [ :task_id, :subject_key, :task_generation ], unique: true,
            where: Sequel.lit("task_id IS NOT NULL AND state IN ('queued', 'claimed')"),
            name: :dispatch_requests_active_subject_uidx
    end

    create_table(:dispatch_outbox) do
      String :delivery_id, primary_key: true, null: false
      foreign_key :request_id, :dispatch_requests, type: String, key: :request_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :kind, null: false
      String :state, null: false
      String :idempotency_key, null: false, unique: true
      String :payload_json, text: true, null: false
      Integer :delivery_attempts, null: false, default: 0
      String :available_at, null: false
      String :delivered_at
      String :retain_until
      check Sequel.lit("state IN ('pending', 'delivered', 'dead')")
      check Sequel.lit("delivery_attempts >= 0")
      index [ :state, :available_at ], name: :dispatch_outbox_ready_idx
    end

    create_table(:attempts) do
      String :attempt_id, primary_key: true, null: false
      foreign_key :request_id, :dispatch_requests, type: String, key: :request_id,
                  on_delete: :set_null, on_update: :cascade
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :subject_kind, null: false
      String :subject_key, null: false
      String :task_generation, null: false
      String :ownership_generation, null: false
      String :state, null: false
      String :outcome
      Integer :lease_version, null: false, default: 0
      String :owner_identity_json, text: true
      String :routing_json, text: true, null: false
      String :source_fingerprint, null: false
      String :checkpoint_json, text: true
      String :record_json, text: true, null: false
      String :record_digest, null: false
      String :subject_json, text: true, null: false
      String :project_name, null: false
      String :task_slug, null: false
      String :accepted_date, null: false
      String :terminal_receipt_digest
      String :created_at, null: false
      String :accepted_at, null: false
      String :started_at
      String :heartbeat_at
      String :ended_at
      String :retain_until
      check Sequel.lit("lease_version >= 0")
      check Sequel.lit("subject_kind IN ('task_stage', 'module_hook')")
      check Sequel.lit("state IN ('launching', 'running', 'terminal', 'lost')")
      check Sequel.lit("outcome IS NULL OR outcome IN ('succeeded', 'failed', 'cancelled')")
      check Sequel.lit("(state = 'terminal' AND outcome IS NOT NULL) OR (state != 'terminal' AND outcome IS NULL)")
      index [ :request_id ], unique: true, where: Sequel.lit("request_id IS NOT NULL"),
            name: :attempts_request_uidx
      index [ :task_id, :subject_key, :task_generation ], unique: true,
            where: Sequel.lit("state IN ('launching', 'running')"),
            name: :attempts_active_subject_generation_uidx
      index [ :state, :heartbeat_at ], name: :attempts_live_idx
      index [ :task_id, :task_generation, :ended_at ], name: :attempts_terminal_idx
      index [ :project_name, :accepted_date ], name: :attempts_daily_idx
    end

    create_table(:attempt_relationships) do
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      foreign_key :related_attempt_id, :attempts, type: String, key: :attempt_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :kind, null: false
      String :created_at, null: false
      primary_key [ :attempt_id, :related_attempt_id, :kind ]
      check Sequel.lit("attempt_id != related_attempt_id")
      check Sequel.lit("kind IN ('predecessor', 'successor', 'retry', 'supersedes')")
      index [ :related_attempt_id, :kind ], unique: true,
            where: Sequel.lit("kind = 'successor'"),
            name: :attempt_relationships_successor_uidx
    end

    create_table(:attempt_accounting) do
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  primary_key: true, null: false, on_delete: :cascade, on_update: :cascade
      String :provider_account_id
      Integer :retry_charge, null: false, default: 0
      Integer :refunded, null: false, default: 0
      String :reservation_json, text: true, null: false, default: "{}"
      String :billing_json, text: true, null: false, default: "{}"
      String :updated_at, null: false
      check Sequel.lit("retry_charge >= 0")
      check Sequel.lit("refunded IN (0, 1)")
    end

    create_table(:attempt_lost_outcomes) do
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  primary_key: true, null: false, on_delete: :cascade, on_update: :cascade
      String :idempotency_key, null: false, unique: true
      String :status, null: false
      String :cleanup
      foreign_key :successor_attempt_id, :attempts, type: String, key: :attempt_id,
                  on_delete: :set_null, on_update: :cascade
      String :value_json, text: true, null: false
      Integer :revision, null: false, default: 0
      String :updated_at, null: false
      check Sequel.lit("status IN ('pending', 'ready', 'successor_dispatched')")
      check Sequel.lit("cleanup IS NULL OR cleanup IN ('absent', 'terminated', 'no_worker', 'identity_mismatch', 'identity_changed', 'still_alive')")
      check Sequel.lit("revision >= 0")
    end

    create_table(:attempt_routing_decisions) do
      String :decision_key, primary_key: true, null: false
      String :task_generation, null: false
      String :subject_json, text: true, null: false
      String :project_name, null: false
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  on_delete: :set_null, on_update: :cascade
      String :decision_id, null: false
      String :decision_json, text: true, null: false
      String :decided_at, null: false
      String :updated_at, null: false
      index [ :decided_at, :decision_id ], name: :attempt_routing_decisions_order_idx
    end

    create_table(:attempt_failure_cohorts) do
      String :utc_date, null: false
      String :identity_digest, null: false
      String :identity_json, text: true, null: false
      Integer :failure_count, null: false, default: 0
      String :retry_at
      foreign_key :probe_attempt_id, :attempts, type: String, key: :attempt_id,
                  on_delete: :set_null, on_update: :cascade
      String :probe_expires_at
      String :updated_at, null: false
      primary_key [ :utc_date, :identity_digest ]
      check Sequel.lit("failure_count >= 0")
    end

    create_table(:attempt_failure_events) do
      String :utc_date, null: false
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :identity_digest
      String :outcome, null: false
      String :occurred_at, null: false
      primary_key [ :utc_date, :attempt_id ]
      check Sequel.lit("outcome IN ('failed', 'succeeded')")
    end

    create_table(:capacity_reservations) do
      String :reservation_id, primary_key: true, null: false
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :scope_kind, null: false
      String :scope_key, null: false
      Integer :units, null: false
      String :state, null: false
      String :created_at, null: false
      String :released_at
      check Sequel.lit("units > 0")
      check Sequel.lit("state IN ('reserved', 'released')")
      index [ :scope_kind, :scope_key, :state ], name: :capacity_reservations_scope_idx
      index [ :attempt_id, :scope_kind, :scope_key ], unique: true,
            where: Sequel.lit("state = 'reserved'"),
            name: :capacity_reservations_active_uidx
    end

    create_table(:terminal_pending_publications) do
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  primary_key: true, null: false, on_delete: :cascade, on_update: :cascade
      String :task_source_fingerprint, null: false
      String :receipt_json, text: true, null: false
      String :expected_receipt_digest, null: false
      String :publication_json, text: true
      String :state, null: false, default: "pending"
      String :created_at, null: false
      String :published_at
      check Sequel.lit("state IN ('pending', 'published')")
      index [ :state, :created_at ], name: :terminal_pending_ready_idx
    end

    create_table(:provider_circuits) do
      String :circuit_id, primary_key: true, null: false
      String :scope_kind, null: false
      String :provider_account_id, null: false
      String :model, null: false, default: ""
      String :automatic_state, null: false
      Integer :manual_block, null: false, default: 0
      String :manual_block_json, text: true
      Integer :generation, null: false, default: 0
      Integer :journal_epoch, null: false, default: 0
      foreign_key :probe_attempt_id, :attempts, type: String, key: :attempt_id,
                  on_delete: :set_null, on_update: :cascade
      String :probe_json, text: true
      String :eligible_at
      String :evidence_json, text: true
      String :last_event_id
      String :updated_at, null: false
      check Sequel.lit("scope_kind IN ('provider_account', 'model')")
      check Sequel.lit("automatic_state IN ('closed', 'open')")
      check Sequel.lit("manual_block IN (0, 1)")
      check Sequel.lit("generation >= 0")
      check Sequel.lit("journal_epoch >= 0")
      check Sequel.lit("(manual_block = 0 AND manual_block_json IS NULL) OR (manual_block = 1 AND manual_block_json IS NOT NULL)")
      check Sequel.lit("(probe_attempt_id IS NULL AND probe_json IS NULL) OR (probe_attempt_id IS NOT NULL AND probe_json IS NOT NULL)")
      unique [ :scope_kind, :provider_account_id, :model ], name: :provider_circuits_scope_uidx
      index [ :probe_attempt_id ],
            where: Sequel.lit("probe_attempt_id IS NOT NULL"),
            name: :provider_circuits_probe_idx
    end

    create_table(:provider_audit) do
      String :event_id, primary_key: true, null: false
      foreign_key :circuit_id, :provider_circuits, type: String, key: :circuit_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      Integer :generation, null: false
      Integer :sequence, null: false
      String :event_type, null: false
      String :idempotency_key, null: false
      String :status, null: false
      String :reason
      String :payload_json, text: true, null: false
      String :occurred_at, null: false
      String :retain_until
      check Sequel.lit("generation >= 0")
      check Sequel.lit("sequence > 0")
      check Sequel.lit("status IN ('accepted', 'rejected')")
      unique [ :circuit_id, :idempotency_key ], name: :provider_audit_idempotency_uidx
      unique [ :circuit_id, :sequence ], name: :provider_audit_sequence_uidx
      index [ :occurred_at ], name: :provider_audit_occurred_idx
    end

    create_table(:pr_merge_reconciliations) do
      String :reconciliation_id, primary_key: true, null: false
      foreign_key :project_id, :projects, type: String, key: :project_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  on_delete: :set_null, on_update: :cascade
      String :task_generation, null: false
      String :repository_identity, null: false
      String :registration_id, null: false
      String :project_path, null: false
      String :state_root_path, null: false
      String :host, null: false
      String :default_branch, null: false
      Integer :pr_number, null: false
      String :merge_sha
      String :state, null: false
      Integer :retry_failures, null: false, default: 0
      String :retry_not_before
      String :remote_state, null: false, default: "unknown"
      String :architecture_state, null: false, default: "pending"
      String :archive_state, null: false, default: "pending"
      Integer :held, null: false, default: 0
      String :hold_reason
      Integer :revision, null: false, default: 0
      String :observation_json, text: true, null: false
      String :observed_at, null: false
      String :updated_at, null: false
      String :completed_at
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
      String :holder_kind
      String :holder_id
      Integer :holder_pid
      String :holder_process_identity
      String :payload_json, text: true, null: false, default: "{}"
      Integer :generation, null: false
      Integer :lease_version, null: false
      String :source_fingerprint, null: false
      String :acquired_at
      String :expires_at
      String :released_at
      check Sequel.lit("generation >= 0")
      check Sequel.lit("lease_version >= 0")
      check Sequel.lit("holder_pid IS NULL OR holder_pid > 0")
      check Sequel.lit("(holder_id IS NULL AND holder_pid IS NULL) OR (holder_id IS NOT NULL AND holder_pid IS NOT NULL)")
      index [ :expires_at ], name: :task_leases_expiry_idx
    end

    create_table(:task_counters) do
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :namespace, null: false
      Integer :value, null: false
      String :updated_at, null: false
      primary_key [ :installation_id, :namespace ]
      check Sequel.lit("value >= 0")
    end

    create_table(:patrol_allowances) do
      foreign_key :project_id, :projects, type: String, key: :project_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :kind, null: false
      String :window_key, null: false
      Integer :used, null: false, default: 0
      Integer :limit_value, null: false
      Integer :revision, null: false, default: 0
      String :reservation_ids_json, text: true, null: false, default: "[]"
      String :seed_state, null: false, default: "complete"
      Integer :seeded_launches, null: false, default: 0
      Integer :ambiguous_rows, null: false, default: 0
      String :retry_not_before
      String :hold_reason
      String :updated_at, null: false
      primary_key [ :project_id, :kind, :window_key ]
      check Sequel.lit("used >= 0")
      check Sequel.lit("limit_value >= 0")
      check Sequel.lit("used <= limit_value")
      check Sequel.lit("revision >= 0")
      check Sequel.lit("seed_state IN ('complete', 'parked')")
      check Sequel.lit("seeded_launches >= 0")
      check Sequel.lit("ambiguous_rows >= 0")
    end

    create_table(:token_usage) do
      String :id, primary_key: true, null: false
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  on_delete: :set_null, on_update: :cascade
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  on_delete: :set_null, on_update: :cascade
      String :session_id
      String :agent, null: false
      String :model
      String :requested_backend
      String :requested_model
      String :actual_backend
      String :actual_model
      String :project_slug
      String :task_slug
      String :stage
      String :started_at, null: false
      String :ended_at
      Integer :input, null: false, default: 0
      Integer :output, null: false, default: 0
      Integer :cached, null: false, default: 0
      Integer :cache_read
      Integer :cache_write
      Integer :reasoning
      Float :cost
      Integer :input_available, null: false, default: 1
      Integer :output_available, null: false, default: 1
      Integer :cached_available, null: false, default: 1
      Integer :cache_read_available, null: false, default: 0
      Integer :cache_write_available, null: false, default: 0
      Integer :reasoning_available, null: false, default: 0
      Integer :cost_available, null: false, default: 0
      Integer :task_generation
      String :source
      String :billing_route
      String :billing_evidence_source
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
      String :daemon_kind, null: false
      Integer :generation, null: false
      String :state, null: false
      Integer :owner_pid
      String :owner_process_identity
      String :observation_json, text: true, null: false, default: "{}"
      String :observed_at, null: false
      String :expires_at
      primary_key [ :installation_id, :daemon_kind ]
      check Sequel.lit("generation >= 0")
      check Sequel.lit("owner_pid IS NULL OR owner_pid > 0")
      check Sequel.lit("state IN ('starting', 'running', 'stopping', 'stopped', 'unavailable')")
    end

    create_table(:payload_references) do
      String :payload_id, primary_key: true, null: false
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  on_delete: :cascade, on_update: :cascade
      foreign_key :attempt_id, :attempts, type: String, key: :attempt_id,
                  on_delete: :cascade, on_update: :cascade
      String :kind, null: false
      String :relative_path, null: false
      String :sha256
      Integer :bytes
      String :state, null: false
      String :created_at, null: false
      String :retain_until
      check Sequel.lit("task_id IS NOT NULL OR attempt_id IS NOT NULL")
      check Sequel.lit("state IN ('open', 'sealed', 'pinned', 'releasable')")
      check Sequel.lit(
        "(state = 'open' AND sha256 IS NULL AND bytes IS NULL) OR " \
        "(state != 'open' AND sha256 IS NOT NULL AND length(sha256) = 64 " \
        "AND bytes IS NOT NULL AND bytes >= 0)"
      )
      index [ :kind, :relative_path ], name: :payload_references_path_idx
      index [ :retain_until ], name: :payload_references_retention_idx
    end

    create_table(:projections) do
      String :projection_key, primary_key: true, null: false
      String :source_kind, null: false
      String :source_id, null: false
      Integer :source_generation, null: false
      String :source_fingerprint, null: false
      String :value_json, text: true, null: false
      String :created_at, null: false
      String :expires_at
      check Sequel.lit("source_generation >= 0")
      index [ :source_kind, :source_id, :source_generation ],
            name: :projections_source_idx
      index [ :expires_at ], name: :projections_expiry_idx
    end

    create_table(:maintenance_checkpoints) do
      String :checkpoint_id, primary_key: true, null: false
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :kind, null: false
      String :state, null: false
      Integer :generation, null: false
      String :payload_json, text: true, null: false
      String :created_at, null: false
      String :completed_at
      check Sequel.lit("generation >= 0")
      check Sequel.lit("state IN ('prepared', 'running', 'completed', 'failed')")
      index [ :kind, :state, :created_at ], name: :maintenance_checkpoints_state_idx
    end
  end
end
