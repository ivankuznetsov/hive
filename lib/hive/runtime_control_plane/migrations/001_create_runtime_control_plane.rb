Sequel.migration do
  up do
    run "PRAGMA application_id = #{Hive::RuntimeControlPlane::APPLICATION_ID}"

    create_table(:installations) do
      String :installation_id, primary_key: true, null: false
      Integer :activation_epoch, null: false, default: 0
      String :created_at, null: false
      String :activated_at
      Integer :next_task_id
      check Sequel.lit("activation_epoch >= 0")
      check Sequel.lit("next_task_id IS NULL OR next_task_id >= 1")
    end

    create_table(:runtime_lifecycle) do
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  primary_key: true, null: false, on_delete: :cascade, on_update: :cascade
      String :phase, null: false, default: "running"
      Integer :generation, null: false, default: 0
      Integer :revision, null: false, default: 0
      Integer :mutation_sequence, null: false, default: 0
      String :boot_id
      Float :deadline_monotonic
      Float :shutdown_grace_sec
      String :interrupted_attempt_ids_json, text: true, null: false, default: "[]"
      String :quiesce_started_at
      String :paused_at
      String :resumed_at
      String :updated_at, null: false
      check Sequel.lit("phase IN ('running', 'quiescing', 'paused', 'resuming')")
      check Sequel.lit("generation >= 0 AND revision >= 0 AND mutation_sequence >= 0")
      check Sequel.lit("deadline_monotonic IS NULL OR deadline_monotonic >= 0")
      check Sequel.lit("shutdown_grace_sec IS NULL OR shutdown_grace_sec >= 0")
    end

    create_table(:launch_reservations) do
      String :reservation_id, primary_key: true, null: false
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      String :attempt_id
      String :task_id
      String :origin, null: false
      String :role, null: false
      String :state, null: false
      Integer :admission_generation, null: false
      Integer :owner_pid
      String :owner_start_fingerprint
      String :reason
      String :created_at, null: false
      String :updated_at, null: false
      check Sequel.lit("state IN ('reserved', 'registered', 'cancelled_by_quiesce', 'released')")
      check Sequel.lit("admission_generation >= 0")
      check Sequel.lit("owner_pid IS NULL OR owner_pid > 0")
      index [ :installation_id, :state ], name: :launch_reservations_installation_state_idx
      index [ :attempt_id ], name: :launch_reservations_attempt_idx
    end

    create_table(:owned_processes) do
      String :process_id, primary_key: true, null: false
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      foreign_key :reservation_id, :launch_reservations, type: String, key: :reservation_id,
                  on_delete: :set_null, on_update: :cascade
      String :attempt_id
      String :task_id
      String :service_identity
      String :origin, null: false
      String :role, null: false
      Integer :pid
      String :start_fingerprint
      Integer :process_group_id
      Integer :session_id
      String :state, null: false
      Integer :proven_child_safe, null: false, default: 0
      String :custody_mode, null: false, default: "unverified"
      String :custody_path
      String :custody_evidence_json, text: true
      String :unknown_reason
      String :created_at, null: false
      String :updated_at, null: false
      String :stopped_at
      check Sequel.lit("pid IS NULL OR pid > 0")
      check Sequel.lit("process_group_id IS NULL OR process_group_id > 0")
      check Sequel.lit("session_id IS NULL OR session_id > 0")
      check Sequel.lit("proven_child_safe IN (0, 1)")
      check Sequel.lit("state IN ('starting', 'running', 'stopping', 'stopped', 'unknown')")
      index [ :installation_id, :state ], name: :owned_processes_installation_state_idx
      index [ :reservation_id ], name: :owned_processes_reservation_idx
      index [ :attempt_id ], name: :owned_processes_attempt_idx
      index [ :pid ], name: :owned_processes_pid_idx
    end

    create_table(:quiescence_cleanup_writes) do
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      Integer :generation, null: false
      String :attempt_id, null: false
      String :created_at, null: false
      primary_key [ :installation_id, :generation, :attempt_id ],
                  name: :quiescence_cleanup_writes_pk
      check Sequel.lit("generation >= 0")
    end

    create_table(:projects) do
      String :project_id, primary_key: true, null: false
      foreign_key :installation_id, :installations, type: String, key: :installation_id,
                  null: false, on_delete: :cascade, on_update: :cascade
      %i[registration_id name observed_path state_root_path].each { |column| String column, null: false }
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
      String :request_id # Immutable provenance, not ownership by the disposable queue row.
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
      %i[admission_workflow admission_runtime_digest].each do |column|
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
      Integer :publication_promoted, null: false, default: 0
      String :source_fingerprint, null: false
      String :details_json, text: true, null: false
      String :subject_json, text: true, null: false
      %i[project_name task_slug accepted_date].each { |column| String column, null: false }
      %i[created_at accepted_at].each { |column| String column, null: false }
      check Sequel.lit("lease_version >= 0")
      check Sequel.lit("retry_charge >= 0")
      check Sequel.lit("refunded IN (0, 1)")
      check Sequel.lit(
        "publication_journal_acknowledged IN (0, 1) AND " \
        "publication_accounting_acknowledged IN (0, 1) AND " \
        "publication_dispatch_acknowledged IN (0, 1) AND publication_promoted IN (0, 1)"
      )
      check Sequel.lit("subject_kind IN ('task_stage', 'module_hook')")
      check Sequel.lit(
        "(subject_kind = 'task_stage' AND task_id IS NOT NULL) OR " \
        "(subject_kind = 'module_hook' AND task_id IS NULL)"
      )
      check Sequel.lit("state IN ('launching', 'running', 'terminal', 'lost')")
      check Sequel.lit(
        "outcome IS NULL OR outcome IN ('succeeded', 'failed', 'cancelled', 'interrupted')"
      )
      check Sequel.lit("(state = 'terminal' AND outcome IS NOT NULL) OR (state != 'terminal' AND outcome IS NULL)")
      check Sequel.lit(
        "(admission_workflow IS NULL AND admission_runtime_digest IS NULL) OR " \
        "(admission_workflow = 'patrol_fix' AND length(admission_runtime_digest) = 64)"
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
        "publication_accounting_acknowledged = 0 AND publication_dispatch_acknowledged = 0 AND " \
        "publication_promoted = 0) OR " \
        "(state IN ('terminal', 'lost') AND terminal_receipt_json IS NOT NULL AND " \
        "length(terminal_receipt_digest) = 64 AND terminal_task_source_fingerprint IS NOT NULL AND " \
        "terminal_publication_created_at IS NOT NULL AND " \
        "(publication_promoted = 0 OR " \
        "(publication_journal_acknowledged = 1 AND publication_accounting_acknowledged = 1 AND " \
        "publication_dispatch_acknowledged = 1)))"
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
              "terminal_receipt_json IS NOT NULL AND publication_promoted = 0"
            ),
            name: :attempts_publication_pending_idx
    end

    create_table(:task_leases) do
      foreign_key :task_id, :task_subjects, type: String, key: :task_id,
                  primary_key: true, null: false, on_delete: :cascade, on_update: :cascade
      %i[holder_id holder_process_identity].each { |column| String column }
      Integer :holder_pid
      String :payload_json, text: true, null: false, default: "{}"
      Integer :lease_version, null: false
      check Sequel.lit("lease_version >= 0")
      check Sequel.lit("holder_pid IS NULL OR holder_pid > 0")
      check Sequel.lit("(holder_id IS NULL AND holder_pid IS NULL) OR (holder_id IS NOT NULL AND holder_pid IS NOT NULL)")
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
                  primary_key: true, null: false, on_delete: :cascade, on_update: :cascade
      String :observation_json, text: true, null: false, default: "{}"
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
      check Sequel.lit("state = 'releasable' OR retain_until IS NULL")
      index [ :kind, :relative_path ], name: :payload_references_path_idx
      index [ :task_id ], name: :payload_references_task_idx
      index [ :attempt_id ], name: :payload_references_attempt_idx
      index [ :retain_until ], name: :payload_references_retention_idx
    end
  end
end
