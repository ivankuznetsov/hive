require "digest"
require "hive/atomic_file"
require "hive/user_service/definition"
require "hive/user_service/status"
require "hive/user_service/plan"
require "hive/user_service/result"
require "hive/user_service/manager"
require "hive/user_service/transaction"

module Hive
  class UserService
    NO_MANAGER_INSPECTION = Manager::Inspection.new(
      availability: :conclusively_absent,
      enabled: false,
      running: false,
      diagnostics: []
    ).freeze
    APPLY_PHASE_ORDER = %w[
      prepared backup_stored unit_published manager_reloaded takeover_completed
      activated verified committed
    ].freeze
    REMOVE_PHASE_ORDER = %w[
      removal_prepared manager_disabled unit_removed removal_reloaded removal_verified
    ].freeze
    LIFECYCLE_PHASE_ORDER = %w[
      lifecycle_prepared lifecycle_acted lifecycle_verified lifecycle_committed
    ].freeze

    def initialize(definition:, runner: nil, query_available: false, manager_available: false,
                   status_reader: nil, launchd_running_via_list: false,
                   writer: nil, clock: -> { Time.now.utc },
                   event_handler: nil, home: nil,
                   lock_wait: Transaction::LOCK_WAIT_SEC, legacy_takeover: nil)
      @definition = definition
      @writer = writer
      @clock = clock
      @event_handler = event_handler
      @legacy_takeover = legacy_takeover
      @manager = Manager.new(
        definition: definition,
        runner: runner,
        query_available: query_available,
        manager_available: manager_available,
        status_reader: status_reader,
        launchd_running_via_list: launchd_running_via_list,
        event_handler: event_handler
      )
      @transaction = if definition.target_path
        Transaction.new(
          definition: definition,
          home: home || home_for_target(definition.target_path),
          clock: clock,
          lock_wait: lock_wait
        )
      end
    end

    def inspect
      inspect_status(manager: true)
    end

    def plan(autostart:, force: false, restart_if_running: false)
      if @definition.platform != :unsupported && !@definition.content
        raise ArgumentError, "service content is required to plan an apply"
      end

      status = inspect_status(manager: false)
      action = apply_action(status, force: force)
      manager_observed = autostart && manager_action?(action)
      if manager_observed
        status = inspect_status(manager: true)
        action = apply_action(status, force: force)
      end
      Plan.new(
        operation: :apply,
        action: action,
        definition_fingerprint: @definition.fingerprint,
        expected_observation: status.observation_key,
        status: status,
        manager_observed: manager_observed,
        autostart: autostart,
        force: force,
        restart_if_running: restart_if_running
      )
    end

    def plan_remove(inspect_absent_manager: true)
      status = inspect_status(manager: false)
      manager_observed = @definition.platform != :unsupported &&
        (inspect_absent_manager || status.content_state != :absent)
      status = inspect_status(manager: true) if manager_observed
      Plan.new(
        operation: :remove,
        action: status.content_state == :absent ? :none : :remove,
        definition_fingerprint: @definition.fingerprint,
        expected_observation: status.observation_key,
        status: status,
        manager_observed: manager_observed
      )
    end

    def apply(plan)
      validate_plan!(plan, :apply)
      return result(:unsupported, final_status: inspect_status(manager: false)) unless @transaction

      @transaction.with_lock do |transaction|
        if (recovery = reconcile_pending(transaction))
          return recovery
        end
        current = inspect_status(manager: plan.manager_observed)
        return stale_result(:apply, current) unless current.observation_key == plan.expected_observation

        apply_current(plan, current, transaction)
      end
    rescue ArgumentError
      raise
    rescue Transaction::Busy => error
      Result.new(
        :failed,
        operation: :apply,
        final_status: safe_inspect(manager: plan.manager_observed),
        diagnostics: [ :operation_busy ],
        error: error
      )
    rescue Transaction::Unsafe, TransactionJournal::Invalid, AppliedReceipt::Invalid => error
      Result.new(
        :failed,
        operation: :apply,
        final_status: safe_inspect(manager: plan.manager_observed),
        diagnostics: [ :invalid_recovery_state ],
        error: error
      )
    rescue StandardError => error
        Result.new(
          :failed,
          operation: :apply,
          final_status: safe_inspect(manager: plan.manager_observed),
          diagnostics: [ :write_failed ],
          error: error
        )
    end

    def remove(plan)
      validate_plan!(plan, :remove)
      return result(:absent, operation: :remove, final_status: inspect_status(manager: false)) unless @transaction

      @transaction.with_lock do |transaction|
        receipt = transaction.receipt.read
        if (recovery = reconcile_pending(transaction))
          return recovery unless recovery.success?
          return recovery if recovery.operation == :remove
          plan = plan_remove
          receipt = transaction.receipt.read
        end
        remove_current(plan, transaction, receipt: receipt)
      end
    rescue ArgumentError
      raise
    rescue Transaction::Busy => error
      Result.new(
        :failed,
        operation: :remove,
        final_status: safe_inspect(manager: plan.manager_observed),
        diagnostics: [ :operation_busy ],
        error: error
      )
    rescue Transaction::Unsafe, TransactionJournal::Invalid, AppliedReceipt::Invalid => error
      Result.new(
        :failed,
        operation: :remove,
        final_status: safe_inspect(manager: plan.manager_observed),
        diagnostics: [ :invalid_recovery_state ],
        error: error
      )
    rescue Errno::ENOENT
      result(:absent, operation: :remove, final_status: inspect_status(manager: plan.manager_observed))
    rescue StandardError => error
      Result.new(
        :failed,
        operation: :remove,
        final_status: safe_inspect(manager: plan.manager_observed),
        diagnostics: [ :remove_failed ],
        error: error
      )
    end

    def purge(plan)
      remove(plan)
    end

    def start
      lifecycle(:start)
    end

    def stop
      lifecycle(:stop)
    end

    def restart
      lifecycle(:restart)
    end

    def takeover
      lifecycle(:takeover)
    end

    def inspect_recovery
      return { "state" => "unsupported" } unless @transaction

      @transaction.receipt.read
      {
        "state" => @transaction.journal.read ? "pending" : "stable",
        "lock_path" => @transaction.lock_path,
        "journal_path" => @transaction.journal.path,
        "receipt_path" => @transaction.receipt.path
      }
    rescue TransactionJournal::Invalid, AppliedReceipt::Invalid, Transaction::Unsafe
      {
        "state" => "invalid",
        "lock_path" => @transaction.lock_path,
        "journal_path" => @transaction.journal.path,
        "receipt_path" => @transaction.receipt.path
      }
    end

    private

    def inspect_status(manager:)
      manager_inspection = manager ? @manager.inspect : NO_MANAGER_INSPECTION
      file = inspect_file
      Status.new(
        platform: @definition.platform,
        unit_path: @definition.target_path,
        content_state: file.fetch(:state),
        file_identity: file[:identity],
        manager_availability: manager_inspection.availability,
        enabled: manager_inspection.enabled,
        running: manager_inspection.running,
        load_state: manager_inspection.respond_to?(:load_state) ? manager_inspection.load_state : nil,
        fragment_path: manager_inspection.respond_to?(:fragment_path) ? manager_inspection.fragment_path : nil,
        need_daemon_reload: manager_inspection.respond_to?(:need_daemon_reload) ? manager_inspection.need_daemon_reload : nil,
        main_pid: manager_inspection.respond_to?(:main_pid) ? manager_inspection.main_pid : nil,
        process_start: manager_inspection.respond_to?(:process_start) ? manager_inspection.process_start : nil,
        manager_evidence_source: manager_inspection.respond_to?(:evidence_source) ? manager_inspection.evidence_source : :observed,
        diagnostics: manager_inspection.diagnostics + file.fetch(:diagnostics)
      )
    end

    def remove_current(plan, transaction, receipt: nil)
      planned = inspect_status(manager: plan.manager_observed)
      return stale_result(:remove, planned) unless planned.observation_key == plan.expected_observation

      current = if receipt && !plan.manager_observed
        inspected = inspect_status(manager: true)
        same_file = inspected.content_state == planned.content_state &&
          inspected.file_identity == planned.file_identity
        return stale_result(:remove, inspected) unless same_file

        inspected
      else
        planned
      end
      if current.manager_availability == :indeterminate
        return result(
          :failed,
          operation: :remove,
          final_status: current,
          diagnostics: current.diagnostics + [ :manager_probe_indeterminate ]
        )
      end
      if current.content_state == :absent &&
         (!current.manager_available? || (!current.enabled? && !current.running? && manager_removed?(current)))
        transaction.clear_after_verified_removal
        return result(:absent, operation: :remove, final_status: current)
      end
      if %i[unsafe unreadable].include?(current.content_state)
        return result(
          :unsafe_path,
          operation: :remove,
          final_status: current,
          diagnostics: current.diagnostics + [ :unsafe_unit_path ]
        )
      end

      prior_content = if current.content_state == :absent
        nil
      else
        bound_file_content(current.file_identity)
      end
      if current.content_state != :absent && !prior_content
        return stale_result(:remove, inspect_status(manager: plan.manager_observed))
      end

      document = transaction.journal.prepare(
        operation: :remove,
        prior_content: prior_content,
        prior_digest: current.file_identity&.fetch(:digest),
        prior_enabled: current.enabled?,
        prior_running: current.running?,
        desired_digest: nil,
        backup_path: nil,
        manager_intent: current.manager_available? ? :disable : nil,
        result_kind: current.content_state == :absent ? :absent : :removed,
        autostart: true,
        prior_main_pid: current.main_pid,
        prior_process_start: current.process_start
      )
      transition_event(:after_removal_prepared)
      complete_removal(document, transaction, replay: false)
    end

    def unlink_target(expected_identity:)
      current = inspect_file
      return nil if current[:state] == :absent
      unless current[:identity] == expected_identity
        raise TransactionJournal::Invalid, "user-service target changed before unlink"
      end

      @transaction.unlink_target(
        expected_snapshot: expected_identity.fetch(:mutation_snapshot),
        expected_digest: expected_identity.fetch(:digest)
      )
      nil
    rescue Transaction::Unsafe => error
      raise TransactionJournal::Invalid,
            "user-service target changed before unlink: #{error.message}"
    end

    def apply_current(plan, current, transaction = @transaction)
      return result(:unsupported, final_status: current) if plan.action == :unsupported
      return result(
        :unsafe_path,
        final_status: current,
        diagnostics: [ :unsafe_unit_path ]
      ) if plan.action == :unsafe
      return result(
        :drifted,
        final_status: current,
        diagnostics: [ :drift_detected ]
      ) if plan.action == :refuse_drift

      receipt = transaction.receipt.read
      desired_digest = Digest::SHA256.hexdigest(@definition.content)
      if receipt_satisfies?(receipt, desired_digest: desired_digest, plan: plan, status: current) &&
         !(plan.restart_if_running && current.running?)
        kind = receipt.fetch("mode") == "unsupported_autostart" ? :autostart_unavailable : :unchanged
        diagnostics = kind == :autostart_unavailable ? [ :autostart_unavailable ] : []
        return result(kind, final_status: current, diagnostics: diagnostics)
      end

      if plan.autostart && current.manager_availability == :indeterminate
        return result(
          :failed,
          final_status: current,
          diagnostics: current.diagnostics + [ :manager_probe_indeterminate ]
        )
      end

      backup_path = nil
      backup_content = nil
      kind =
        case plan.action
        when :write
          :written
        when :replace
          backup_path = available_backup_path(@definition.target_path)
          backup_content = bound_file_content(current.file_identity)
          return stale_result(:apply, inspect_status(manager: plan.manager_observed)) unless backup_content
          :upgraded
        when :noop
          :unchanged
        else
          raise ArgumentError, "unsupported user service action #{plan.action.inspect}"
        end

      prior_content = if current.content_state == :absent
        nil
      elsif backup_content
        backup_content
      else
        bound_file_content(current.file_identity)
      end
      return stale_result(:apply, inspect_status(manager: plan.manager_observed)) if current.content_state != :absent && !prior_content

      legacy_match = plan.action == :noop && receipt.nil?
      takeover_pending = @legacy_takeover&.pending?
      manager_intent = if plan.autostart && current.manager_available?
        if takeover_pending && !current.running?
          :takeover
        else
          restart_required = plan.action == :replace || legacy_match ||
            (current.running? &&
             (plan.restart_if_running || !manager_definition_current?(current)))
          restart_required ? :restart : :enable
        end
      end
      document = transaction.journal.prepare(
        operation: :apply,
        prior_content: prior_content,
        prior_digest: current.file_identity&.fetch(:digest),
        prior_enabled: current.enabled?,
        prior_running: current.running?,
        desired_digest: desired_digest,
        backup_path: backup_path,
        manager_intent: manager_intent,
        result_kind: kind,
        autostart: plan.autostart,
        prior_main_pid: current.main_pid,
        prior_process_start: current.process_start
      )
      transition_event(:after_journal_prepared)

      if backup_path
        document = ensure_recorded_backup(document, transaction, backup_content)
        transition_event(:after_backup_stored)
      end
      unless apply_phase_at_least?(document, :backup_stored)
        document = transaction.journal.advance(document, phase: :backup_stored)
        transition_event(:after_backup_stored)
      end
      verify_recorded_backup!(document) if backup_path

      if plan.action != :noop
        begin
          publish_desired(expected_identity: current.file_identity)
        rescue TransactionJournal::Invalid => error
          return Result.new(
            :failed,
            backup_path: backup_path,
            final_status: safe_inspect(manager: plan.manager_observed),
            diagnostics: (backup_path ? %i[backup_written invalid_recovery_state recovery_pending] : %i[invalid_recovery_state recovery_pending]),
            error: error
          )
        rescue StandardError => error
          return Result.new(
            :failed,
            backup_path: backup_path,
            final_status: safe_inspect(manager: plan.manager_observed),
            diagnostics: (backup_path ? %i[backup_written write_failed recovery_pending] : %i[write_failed recovery_pending]),
            error: error
          )
        end
      end
      document = transaction.journal.advance(document, phase: :unit_published)
      transition_event(:after_unit_published)

      complete_apply_transition(document, transaction, replay: false)
    end

    def reconcile_pending(transaction)
      transaction.receipt.read
      document = transaction.journal.read
      return nil unless document

      if document.fetch("operation") == "remove"
        return recover_removal(document, transaction)
      end
      if document.fetch("operation") == "lifecycle"
        return recover_lifecycle(document, transaction)
      end

      desired_digest = Digest::SHA256.hexdigest(@definition.content.to_s)
      unless document.fetch("desired_digest") == desired_digest
        return result(
          :failed,
          final_status: safe_inspect(manager: true),
          diagnostics: %i[invalid_recovery_state recovery_pending]
        )
      end
      return rollback_apply(document, transaction, diagnostics: [ :recovery_resumed ]) if document.fetch("direction") == "rollback"

      file = inspect_file
      desired_matches = file.dig(:identity, :digest) == document.fetch("desired_digest")
      prior_matches = recorded_prior_file?(file, document)
      unless desired_matches || prior_matches
        return invalid_recovery_result(operation: :apply)
      end

      prior_content = transaction.journal.prior_content(document)
      document = ensure_recorded_backup(document, transaction, prior_content)
      unless apply_phase_at_least?(document, :backup_stored)
        document = transaction.journal.advance(document, phase: :backup_stored)
      end
      unless desired_matches
        if apply_phase_at_least?(document, :manager_reloaded)
          return invalid_recovery_result(operation: :apply, document: document)
        end
        publish_desired(expected_identity: file[:identity])
      end
      unless apply_phase_at_least?(document, :unit_published)
        document = transaction.journal.advance(document, phase: :unit_published)
      end

      complete_apply_transition(document, transaction, replay: true)
    end

    def complete_apply_transition(document, transaction, replay:)
      backup_path = document.fetch("backup_path")
      diagnostics = []
      diagnostics << :backup_written if backup_path
      diagnostics << :recovery_resumed if replay
      final_without_manager = lambda do |mode, kind, extra_diagnostics|
        final_status = inspect_status(manager: false)
        unless desired_file?(final_status, document)
          return pending_result(
            operation: :apply,
            document: document,
            status: final_status,
            diagnostics: diagnostics + [ :verification_failed ]
          )
        end
        finalize_apply(
          document, transaction,
          mode: mode,
          kind: kind,
          status: final_status,
          diagnostics: diagnostics + extra_diagnostics
        )
      end

      unless document.fetch("autostart")
        return final_without_manager.call(
          :no_autostart, document.fetch("result_kind").to_sym, []
        )
      end

      status = inspect_status(manager: true)
      intent = document.fetch("manager_intent")
      if status.manager_availability == :conclusively_absent && intent.nil?
        return final_without_manager.call(
          :unsupported_autostart, :autostart_unavailable, [ :autostart_unavailable ]
        )
      end
      if intent.nil?
        return pending_result(
          operation: :apply,
          document: document,
          status: status,
          diagnostics: diagnostics + status.diagnostics + [ :recorded_manager_intent_unavailable ]
        ) unless status.manager_available?

        return rollback_apply(document, transaction, diagnostics: diagnostics + [ :recorded_manager_intent_unavailable ])
      end
      unless status.manager_available?
        return pending_result(
          operation: :apply,
          document: document,
          status: status,
          diagnostics: diagnostics + status.diagnostics
        )
      end

      action = nil
      if !apply_phase_at_least?(document, :manager_reloaded)
        reload = @manager.reload
        diagnostics.concat(reload.diagnostics)
        status = inspect_status(manager: true)
        reload_verified = manager_definition_current?(status) &&
          (reload.ok || status.manager_evidence_source != :injected)
        reload_verified ||= reload.ok && status.manager_evidence_source == :injected
        unless reload_verified
          return pending_result(
            operation: :apply,
            document: document,
            status: status,
            diagnostics: diagnostics
          ) unless status.manager_available?

          return rollback_apply(document, transaction, diagnostics: diagnostics)
        end
        diagnostics << :manager_effect_verified unless reload.ok
        document = transaction.journal.advance(document, phase: :manager_reloaded)
        transition_event(:after_manager_reloaded)
        status = inspect_status(manager: true)
      elsif !manager_definition_current?(status)
        reload = @manager.reload
        diagnostics.concat(reload.diagnostics)
        status = inspect_status(manager: true)
        reload_verified = manager_definition_current?(status) &&
          (reload.ok || status.manager_evidence_source != :injected)
        reload_verified ||= reload.ok && status.manager_evidence_source == :injected
        unless reload_verified
          return pending_result(
            operation: :apply,
            document: document,
            status: status,
            diagnostics: diagnostics
          )
        end
      end

      if intent == "takeover" && !apply_phase_at_least?(document, :takeover_completed)
        unless status.running?
          unless @legacy_takeover
            return pending_result(
              operation: :apply,
              document: document,
              status: status,
              diagnostics: diagnostics + [ :legacy_takeover_failed ]
            )
          end

          begin
            stopped = @legacy_takeover.stop!
          rescue StandardError => error
            return Result.new(
              :failed,
              backup_path: backup_path,
              final_status: safe_inspect(manager: true),
              diagnostics: diagnostics + %i[legacy_takeover_failed recovery_pending],
              error: error
            )
          end
          unless stopped
            return pending_result(
              operation: :apply,
              document: document,
              status: safe_inspect(manager: true),
              diagnostics: diagnostics + [ :legacy_takeover_failed ]
            )
          end
        end
        document = transaction.journal.advance(document, phase: :takeover_completed)
        transition_event(:after_takeover_completed)
        status = inspect_status(manager: true)
      end

      unless apply_phase_at_least?(document, :activated)
        # A clean invocation must perform the exact action recorded before
        # publication even when a boolean-only injected inspector happens to
        # report an already-active unit. Replay may finalize from rich endpoint
        # evidence because the prior process could have completed the action
        # before it was interrupted.
        effect = replay ? activation_effect(status, document) : :incomplete
        if effect == :ambiguous
          return pending_result(
            operation: :apply,
            document: document,
            status: status,
            diagnostics: diagnostics + [ :manager_effect_ambiguous ]
          )
        end
        unless effect == :complete
          action = @manager.activate(intent.to_sym)
          diagnostics.concat(action.diagnostics)
          status = inspect_status(manager: true)
          effect = if !action.ok && status.manager_evidence_source == :injected
            :incomplete
          else
            activation_effect(status, document, trusted_action: action.ok)
          end
        end
        unless effect == :complete
          return pending_result(
            operation: :apply,
            document: document,
            status: status,
            diagnostics: diagnostics + (effect == :ambiguous ? [ :manager_effect_ambiguous ] : [])
          ) unless status.manager_available?

          return rollback_apply(document, transaction, diagnostics: diagnostics)
        end
        diagnostics << :manager_effect_verified if action && !action.ok
        document = transaction.journal.advance(document, phase: :activated)
        transition_event(:after_activated)
        status = inspect_status(manager: true)
      end

      if desired_endpoint?(status)
        return finalize_apply(
          document, transaction,
          mode: :managed,
          kind: document.fetch("result_kind").to_sym,
          status: status,
          diagnostics: diagnostics,
          restarted: intent == "restart"
        )
      end

      unless status.manager_available?
        return pending_result(
          operation: :apply,
          document: document,
          status: status,
          diagnostics: diagnostics
        )
      end

      # A durable activation phase is authoritative. If the service regresses
      # before commit, resume its recorded action without moving the journal
      # backwards.
      action = @manager.activate(intent.to_sym)
      diagnostics.concat(action.diagnostics)
      status = inspect_status(manager: true)
      if desired_endpoint?(status)
        diagnostics << :manager_effect_verified unless action.ok
        return finalize_apply(
          document, transaction,
          mode: :managed,
          kind: document.fetch("result_kind").to_sym,
          status: status,
          diagnostics: diagnostics,
          restarted: intent == "restart"
        )
      end

      pending_result(
        operation: :apply,
        document: document,
        status: status,
        diagnostics: diagnostics
      )
    end

    def finalize_apply(document, transaction, mode:, kind:, status:, diagnostics:, restarted: false)
      inspect_manager = mode.to_sym == :managed
      status = inspect_status(manager: inspect_manager)
      unless apply_endpoint_for_mode?(status, document, mode)
        return pending_result(
          operation: :apply,
          document: document,
          status: status,
          diagnostics: diagnostics + [ :verification_failed ]
        )
      end

      unless apply_phase_at_least?(document, :verified)
        document = transaction.journal.advance(document, phase: :verified)
        transition_event(:after_verified)
        status = inspect_status(manager: inspect_manager)
        unless apply_endpoint_for_mode?(status, document, mode)
          return pending_result(
            operation: :apply,
            document: document,
            status: status,
            diagnostics: diagnostics + [ :verification_failed ]
          )
        end
      end
      unless apply_phase_at_least?(document, :committed)
        verify_recorded_backup!(document) if document.fetch("backup_path")
        document = transaction.journal.advance(document, phase: :committed)
        transition_event(:after_committed)
      end

      status = inspect_status(manager: inspect_manager)
      unless apply_endpoint_for_mode?(status, document, mode)
        return pending_result(
          operation: :apply,
          document: document,
          status: status,
          diagnostics: diagnostics + [ :verification_failed ]
        )
      end
      verify_recorded_backup!(document) if document.fetch("backup_path")
      receipt = transaction.receipt.read
      unless receipt &&
             receipt.fetch("desired_digest") == document.fetch("desired_digest") &&
             receipt.fetch("mode") == mode.to_s &&
             receipt.fetch("manager_intent") == document.fetch("manager_intent")
        transaction.receipt.write(
          digest: document.fetch("desired_digest"),
          mode: mode,
          manager_intent: document.fetch("manager_intent")
        )
      end
      transaction.journal.delete
      result(
        kind,
        backup_path: document.fetch("backup_path"),
        restarted: restarted,
        final_status: status,
        diagnostics: diagnostics
      )
    end

    def rollback_apply(document, transaction, diagnostics:)
      document = transaction.journal.advance(
        document, phase: :rollback_selected, direction: :rollback
      ) unless document.fetch("direction") == "rollback"
      if transaction.journal.phase?(document, :rollback_selected)
        transition_event(:after_rollback_selected)
      end

      file = inspect_file
      unless recorded_prior_file?(file, document) || desired_file_observation?(file, document)
        return invalid_recovery_result(operation: :apply, document: document)
      end
      unless recorded_prior_file?(file, document)
        restore_prior_file(document, transaction, expected_identity: file[:identity])
        file = inspect_file
      end
      unless recorded_prior_file?(file, document)
        return pending_result(
          operation: :apply,
          document: document,
          status: safe_inspect(manager: document.fetch("autostart")),
          diagnostics: diagnostics + [ :rollback_file_unverified ]
        )
      end
      if rollback_phase_index(document) < rollback_phase_index("prior_file_restored")
        document = transaction.journal.advance(document, phase: :prior_file_restored)
        transition_event(:after_prior_file_restored)
      end

      inspect_manager = document.fetch("autostart") && !document.fetch("manager_intent").nil?
      manager = Manager::Action.new(ok: true, restarted: false, diagnostics: [])
      status = inspect_status(manager: inspect_manager)
      unless prior_manager_endpoint?(status, document)
        if inspect_manager && !status.manager_available?
          return pending_result(
            operation: :apply,
            document: document,
            status: status,
            diagnostics: diagnostics + status.diagnostics
          )
        end
        manager = @manager.restore(
          prior_enabled: document.fetch("prior_enabled"),
          prior_running: document.fetch("prior_running")
        ) if inspect_manager
        diagnostics.concat(manager.diagnostics)
        status = inspect_status(manager: inspect_manager)
      end
      unless prior_manager_endpoint?(status, document)
        return pending_result(
          operation: :apply,
          document: document,
          status: status,
          diagnostics: diagnostics + [ :rollback_manager_unverified ]
        )
      end
      diagnostics << :manager_effect_verified if inspect_manager && !manager.ok
      if rollback_phase_index(document) < rollback_phase_index("prior_manager_restored")
        document = transaction.journal.advance(document, phase: :prior_manager_restored)
        transition_event(:after_prior_manager_restored)
      end

      status = inspect_status(manager: inspect_manager)
      unless prior_endpoint?(status, document)
        return pending_result(
          operation: :apply,
          document: document,
          status: status,
          diagnostics: diagnostics + [ :rollback_verification_failed ]
        )
      end
      unless transaction.journal.phase?(document, :prior_verified)
        document = transaction.journal.advance(document, phase: :prior_verified)
        transition_event(:after_prior_verified)
      end
      status = inspect_status(manager: inspect_manager)
      unless prior_endpoint?(status, document)
        return pending_result(
          operation: :apply,
          document: document,
          status: status,
          diagnostics: diagnostics + [ :rollback_verification_failed ]
        )
      end
      transaction.receipt.delete
      transaction.journal.delete
      result(
        :failed,
        backup_path: document.fetch("backup_path"),
        restarted: false,
        final_status: status,
        diagnostics: diagnostics + [ :prior_state_restored ]
      )
    end

    def recover_removal(document, transaction)
      complete_removal(document, transaction, replay: true)
    end

    def complete_removal(document, transaction, replay:)
      diagnostics = replay ? [ :recovery_resumed ] : []
      file = inspect_file
      prior_matches = recorded_prior_file?(file, document)
      unless prior_matches || file[:state] == :absent
        return invalid_recovery_result(operation: :remove, document: document)
      end
      if remove_phase_at_least?(document, :unit_removed) && file[:state] != :absent
        return invalid_recovery_result(operation: :remove, document: document)
      end
      if document.fetch("prior_digest") &&
         transaction.journal.phase?(document, :removal_prepared) &&
         file[:state] == :absent
        return invalid_recovery_result(operation: :remove, document: document)
      end

      status = inspect_status(manager: true)
      intent = document.fetch("manager_intent")
      if intent
        unless status.manager_available?
          return pending_result(
            operation: :remove,
            document: document,
            status: status,
            diagnostics: diagnostics + status.diagnostics
          )
        end
        unless manager_disabled?(status)
          disabled = @manager.disable
          diagnostics.concat(disabled.diagnostics)
          status = inspect_status(manager: true)
          unless manager_disabled?(status)
            return pending_result(
              operation: :remove,
              document: document,
              status: status,
              diagnostics: diagnostics
            )
          end
          diagnostics << :manager_effect_verified unless disabled.ok
        end
      end
      unless remove_phase_at_least?(document, :manager_disabled)
        document = transaction.journal.advance(document, phase: :manager_disabled)
        transition_event(:after_manager_disabled)
      end

      file = inspect_file
      unless recorded_prior_file?(file, document) || file[:state] == :absent
        return pending_result(
          operation: :remove,
          document: document,
          status: safe_inspect(manager: true),
          diagnostics: diagnostics + [ :stale_after_manager_change ]
        )
      end
      if file[:state] != :absent
        begin
          unlink_target(expected_identity: file[:identity])
        rescue StandardError => error
          return Result.new(
            :failed,
            operation: :remove,
            final_status: safe_inspect(manager: true),
            diagnostics: (diagnostics + %i[remove_failed recovery_pending]).uniq,
            error: error
          )
        end
      end
      unless inspect_file[:state] == :absent
        return pending_result(
          operation: :remove,
          document: document,
          status: safe_inspect(manager: true),
          diagnostics: diagnostics + [ :remove_failed ]
        )
      end
      unless remove_phase_at_least?(document, :unit_removed)
        document = transaction.journal.advance(document, phase: :unit_removed)
        transition_event(:after_unit_removed)
      end

      status = inspect_status(manager: true)
      if !remove_phase_at_least?(document, :removal_reloaded)
        unless intent
          document = transaction.journal.advance(document, phase: :removal_reloaded)
          transition_event(:after_removal_reloaded)
          status = inspect_status(manager: true)
        else
          if !status.manager_available?
            return pending_result(
              operation: :remove,
              document: document,
              status: status,
              diagnostics: diagnostics + status.diagnostics
            )
          end
          reload = @manager.reload_after_remove
          diagnostics.concat(reload.diagnostics)
          status = inspect_status(manager: true)
          reload_verified = removal_manager_endpoint?(status, document) &&
            (reload.ok || status.manager_evidence_source != :injected)
          unless reload_verified
            return pending_result(
              operation: :remove,
              document: document,
              status: status,
              diagnostics: diagnostics
            )
          end
          diagnostics << :manager_effect_verified unless reload.ok
          document = transaction.journal.advance(document, phase: :removal_reloaded)
          transition_event(:after_removal_reloaded)
        end
      elsif !removal_manager_endpoint?(status, document)
        if intent && !status.manager_available?
          return pending_result(
            operation: :remove,
            document: document,
            status: status,
            diagnostics: diagnostics + status.diagnostics
          )
        end
        reload = @manager.reload_after_remove
        diagnostics.concat(reload.diagnostics)
        status = inspect_status(manager: true)
        unless removal_manager_endpoint?(status, document)
          return pending_result(
            operation: :remove,
            document: document,
            status: status,
            diagnostics: diagnostics
          )
        end
      end

      status = inspect_status(manager: true)
      unless removal_endpoint?(status, document)
        return pending_result(
          operation: :remove,
          document: document,
          status: status,
          diagnostics: diagnostics + [ :verification_failed ]
        )
      end
      unless remove_phase_at_least?(document, :removal_verified)
        document = transaction.journal.advance(document, phase: :removal_verified)
        transition_event(:after_removal_verified)
      end
      status = inspect_status(manager: true)
      unless removal_endpoint?(status, document)
        return pending_result(
          operation: :remove,
          document: document,
          status: status,
          diagnostics: diagnostics + [ :verification_failed ]
        )
      end
      transaction.clear_after_verified_removal
      result(
        document.fetch("result_kind").to_sym,
        operation: :remove,
        final_status: status,
        diagnostics: diagnostics
      )
    end

    def receipt_satisfies?(receipt, desired_digest:, plan:, status:)
      return false unless receipt && receipt.fetch("desired_digest") == desired_digest
      return false unless status.content_state == :matching
      return receipt.fetch("mode") == "no_autostart" unless plan.autostart

      case receipt.fetch("mode")
      when "managed"
        desired_endpoint?(status)
      when "unsupported_autostart"
        status.manager_availability == :conclusively_absent
      else
        false
      end
    end

    def desired_endpoint?(status)
      status.content_state == :matching && status.manager_available? &&
        status.enabled? && status.running? && manager_definition_current?(status) &&
        (@definition.platform != :linux || !status.process_identity.nil?)
    end

    def desired_file?(status, document)
      status.file_identity&.fetch(:digest) == document.fetch("desired_digest")
    end

    def desired_file_observation?(file, document)
      file.dig(:identity, :digest) == document.fetch("desired_digest")
    end

    def recorded_prior_file?(file, document)
      digest = document.fetch("prior_digest")
      digest ? file.dig(:identity, :digest) == digest : file[:state] == :absent
    end

    def manager_definition_current?(status)
      return true unless @definition.platform == :linux

      status.loaded_definition_current?
    end

    def manager_removed?(status)
      return true unless @definition.platform == :linux

      %w[not-found not_found].include?(status.load_state) && !status.need_daemon_reload
    end

    def manager_disabled?(status)
      status.manager_available? && !status.enabled? && !status.running?
    end

    def removal_manager_endpoint?(status, document)
      if document.fetch("manager_intent")
        manager_disabled?(status) && manager_removed?(status)
      else
        status.manager_availability == :conclusively_absent
      end
    end

    def removal_endpoint?(status, document)
      status.content_state == :absent && removal_manager_endpoint?(status, document)
    end

    def recorded_process_identity(document)
      pid = document.fetch("prior_main_pid")
      started = document.fetch("prior_process_start")
      return nil unless pid.to_i.positive? && started && !started.empty?

      { main_pid: pid.to_i, process_start: started }
    end

    def activation_effect(status, document, trusted_action: false)
      return :incomplete unless desired_endpoint?(status)
      return :complete if document.fetch("manager_intent") == "enable"
      return :complete unless document.fetch("prior_running")
      return trusted_action ? :complete : :incomplete unless @definition.platform == :linux

      prior = recorded_process_identity(document)
      current = status.process_identity
      return :complete if prior && current && current != prior
      return :complete if trusted_action && current && current.fetch(:process_start) == "injected"
      return :incomplete if prior && current == prior

      :ambiguous
    end

    def apply_endpoint_for_mode?(status, document, mode)
      return false unless desired_file?(status, document)

      case mode.to_sym
      when :managed
        desired_endpoint?(status)
      when :no_autostart
        true
      when :unsupported_autostart
        status.manager_availability == :conclusively_absent
      else
        false
      end
    end

    def prior_manager_endpoint?(status, document)
      return true unless document.fetch("autostart") && document.fetch("manager_intent")
      return false unless status.manager_available? &&
                          status.enabled? == document.fetch("prior_enabled") &&
                          status.running? == document.fetch("prior_running")

      if document.fetch("prior_digest")
        manager_definition_current?(status) &&
          (!status.running? || @definition.platform != :linux || !status.process_identity.nil?)
      else
        manager_removed?(status)
      end
    end

    def prior_endpoint?(status, document)
      file = {
        state: status.content_state,
        identity: status.file_identity
      }
      recorded_prior_file?(file, document) && prior_manager_endpoint?(status, document)
    end

    def lifecycle_effect(status, document, trusted_action: false)
      operation = document.fetch("manager_intent")
      case operation
      when "start"
        status.running? ? :complete : :incomplete
      when "stop"
        status.running? ? :incomplete : :complete
      when "restart", "takeover"
        return :incomplete unless status.running?
        return trusted_action ? :complete : :incomplete unless @definition.platform == :linux

        prior = recorded_process_identity(document)
        current = status.process_identity
        return :complete if prior && current && current != prior
        return :complete if trusted_action && current && current.fetch(:process_start) == "injected"
        return :incomplete if prior && current == prior

        :ambiguous
      else
        :ambiguous
      end
    end

    def lifecycle_endpoint?(status, document)
      operation = document.fetch("manager_intent")
      return !status.running? if operation == "stop"
      return false unless status.running?

      %w[start restart takeover].include?(operation)
    end

    def lifecycle(operation)
      return result(:unsupported, operation: operation, final_status: inspect) unless @transaction

      @transaction.with_lock do |transaction|
        transaction.receipt.read
        if (recovery = reconcile_pending(transaction))
          return recovery unless recovery.success?
          return recovery if recovery.operation == operation
        end
        before = inspect_status(manager: true)
        unless before.manager_available?
          return result(
            :failed,
            operation: operation,
            final_status: before,
            diagnostics: before.diagnostics + [ :manager_action_unavailable ]
          )
        end
        if (operation == :start && before.running?) || (operation == :stop && !before.running?)
          return result(:unchanged, operation: operation, final_status: before)
        end
        unless before.file_identity
          return result(
            :failed,
            operation: operation,
            final_status: before,
            diagnostics: [ :manager_action_unverified ]
          )
        end

        document = transaction.journal.prepare(
          operation: :lifecycle,
          prior_content: nil,
          prior_digest: before.file_identity.fetch(:digest),
          prior_enabled: before.enabled?,
          prior_running: before.running?,
          desired_digest: before.file_identity.fetch(:digest),
          backup_path: nil,
          manager_intent: operation,
          result_kind: :unchanged,
          autostart: true,
          prior_main_pid: before.main_pid,
          prior_process_start: before.process_start
        )
        transition_event(:after_lifecycle_prepared)
        complete_lifecycle(document, transaction, replay: false)
      end
    rescue Transaction::Busy => error
      Result.new(
        :failed,
        operation: operation,
        final_status: safe_inspect(manager: true),
        diagnostics: [ :operation_busy ],
        error: error
      )
    rescue Transaction::Unsafe, TransactionJournal::Invalid, AppliedReceipt::Invalid => error
      Result.new(
        :failed,
        operation: operation,
        final_status: safe_inspect(manager: true),
        diagnostics: [ :invalid_recovery_state ],
        error: error
      )
    end

    def recover_lifecycle(document, transaction)
      complete_lifecycle(document, transaction, replay: true)
    end

    def complete_lifecycle(document, transaction, replay:)
      operation = document.fetch("manager_intent").to_sym
      diagnostics = replay ? [ :recovery_resumed ] : []
      file = inspect_file
      unless file.dig(:identity, :digest) == document.fetch("desired_digest")
        return invalid_recovery_result(operation: operation, document: document)
      end

      status = inspect_status(manager: true)
      unless status.manager_available?
        return pending_result(
          operation: operation,
          document: document,
          status: status,
          diagnostics: diagnostics + status.diagnostics + [ :manager_action_unavailable ]
        )
      end

      unless lifecycle_phase_at_least?(document, :lifecycle_acted)
        effect = lifecycle_effect(status, document)
        if effect == :ambiguous
          return pending_result(
            operation: operation,
            document: document,
            status: status,
            diagnostics: diagnostics + [ :manager_effect_ambiguous ]
          )
        end
        action = nil
        unless effect == :complete
          action = @manager.public_send(operation)
          diagnostics.concat(action.diagnostics)
          status = inspect_status(manager: true)
          effect = lifecycle_effect(status, document, trusted_action: action.ok)
        end
        unless effect == :complete
          return pending_result(
            operation: operation,
            document: document,
            status: status,
            diagnostics: diagnostics + [ :manager_action_unverified ]
          )
        end
        diagnostics << :manager_effect_verified if action && !action.ok
        document = transaction.journal.advance(document, phase: :lifecycle_acted)
        transition_event(:after_lifecycle_acted)
      end

      status = inspect_status(manager: true)
      unless lifecycle_endpoint?(status, document)
        action = @manager.public_send(operation)
        diagnostics.concat(action.diagnostics)
        status = inspect_status(manager: true)
        unless lifecycle_endpoint?(status, document)
          return pending_result(
            operation: operation,
            document: document,
            status: status,
            diagnostics: diagnostics + [ :manager_action_unverified ]
          )
        end
        diagnostics << :manager_effect_verified unless action.ok
      end

      unless lifecycle_phase_at_least?(document, :lifecycle_verified)
        document = transaction.journal.advance(document, phase: :lifecycle_verified)
        transition_event(:after_lifecycle_verified)
        status = inspect_status(manager: true)
        unless lifecycle_endpoint?(status, document)
          return pending_result(
            operation: operation,
            document: document,
            status: status,
            diagnostics: diagnostics + [ :manager_action_unverified ]
          )
        end
      end
      unless lifecycle_phase_at_least?(document, :lifecycle_committed)
        document = transaction.journal.advance(document, phase: :lifecycle_committed)
        transition_event(:after_lifecycle_committed)
      end
      status = inspect_status(manager: true)
      unless lifecycle_endpoint?(status, document)
        return pending_result(
          operation: operation,
          document: document,
          status: status,
          diagnostics: diagnostics + [ :manager_action_unverified ]
        )
      end
      transaction.journal.delete
      result(
        :unchanged,
        operation: operation,
        restarted: %i[restart takeover].include?(operation),
        final_status: status,
        diagnostics: diagnostics
      )
    end

    def apply_phase_at_least?(document, phase)
      phase_index(APPLY_PHASE_ORDER, document.fetch("phase")) >=
        phase_index(APPLY_PHASE_ORDER, phase)
    end

    def remove_phase_at_least?(document, phase)
      phase_index(REMOVE_PHASE_ORDER, document.fetch("phase")) >=
        phase_index(REMOVE_PHASE_ORDER, phase)
    end

    def lifecycle_phase_at_least?(document, phase)
      phase_index(LIFECYCLE_PHASE_ORDER, document.fetch("phase")) >=
        phase_index(LIFECYCLE_PHASE_ORDER, phase)
    end

    def rollback_phase_index(document_or_phase)
      phase = document_or_phase.is_a?(Hash) ? document_or_phase.fetch("phase") : document_or_phase
      phase_index(TransactionJournal::APPLY_ROLLBACK_PHASES, phase)
    end

    def phase_index(order, phase)
      order.index(phase.to_s) || raise(
        TransactionJournal::Invalid,
        "unrecognized user-service transition phase #{phase.inspect}"
      )
    end

    def pending_result(operation:, document:, status:, diagnostics:)
      result(
        :failed,
        operation: operation,
        backup_path: document && document["backup_path"],
        restarted: false,
        final_status: status,
        diagnostics: (Array(diagnostics) + [ :recovery_pending ]).uniq
      )
    end

    def invalid_recovery_result(operation:, document: nil)
      pending_result(
        operation: operation,
        document: document,
        status: safe_inspect(manager: true),
        diagnostics: [ :invalid_recovery_state ]
      )
    end

    def restore_prior_file(document, transaction, expected_identity:)
      prior_content = transaction.journal.prior_content(document)
      if prior_content
        publish_content(prior_content, expected_identity: expected_identity)
      else
        unlink_target(expected_identity: expected_identity)
      end
    end

    def transition_event(event)
      @event_handler&.call(event, @definition)
    end

    def apply_action(status, force:)
      return :unsupported if @definition.platform == :unsupported

      case status.content_state
      when :absent then :write
      when :matching then :noop
      when :drifted then force ? :replace : :refuse_drift
      else :unsafe
      end
    end

    def manager_action?(action)
      %i[write replace noop].include?(action)
    end

    def validate_plan!(plan, operation)
      raise ArgumentError, "expected Hive::UserService::Plan" unless plan.is_a?(Plan)
      raise ArgumentError, "expected #{operation} plan, got #{plan.operation}" unless plan.operation == operation
      unless plan.definition_fingerprint == @definition.fingerprint
        raise ArgumentError, "plan belongs to a different service definition"
      end
      return if canonical_plan?(plan)

      raise ArgumentError, "plan decision does not match its observed service state"
    end

    def canonical_plan?(plan)
      if plan.operation == :apply
        expected_action = apply_action(plan.status, force: plan.force)
        plan.action == expected_action &&
          plan.manager_observed == (plan.autostart && manager_action?(expected_action))
      else
        expected_action = plan.status.content_state == :absent ? :none : :remove
        manager_observation_valid = if @definition.platform == :unsupported
          !plan.manager_observed
        elsif plan.status.content_state == :absent
          true
        else
          plan.manager_observed
        end
        plan.action == expected_action &&
          manager_observation_valid &&
          !plan.autostart &&
          !plan.force &&
          !plan.restart_if_running
      end
    end

    def stale_result(operation, current)
      result(
        :stale,
        operation: operation,
        final_status: current,
        diagnostics: [ :stale_plan ]
      )
    end

    def inspect_file
      return { state: :absent, identity: nil, diagnostics: [] } unless @definition.target_path

      lexical_stat = File.lstat(@definition.target_path)
      return unsafe_file_observation(lexical_stat) unless lexical_stat.file?

      stat, content = read_regular_file
      return unsafe_file_observation(stat) unless stat.file?

      file_observation(
        @definition.content && content.b == @definition.content.b ? :matching : :drifted,
        stat: stat,
        digest: Digest::SHA256.hexdigest(content)
      )
    rescue Errno::ENOENT
      file_observation(:absent)
    rescue Errno::ELOOP
      unsafe_file_observation(lexical_stat)
    rescue Errno::EACCES, Errno::EPERM
      file_observation(:unreadable, stat: lexical_stat, diagnostics: [ :unit_unreadable ])
    end

    def bound_file_content(expected_identity)
      stat, content = read_regular_file
      return unless stat.file?

      identity = file_identity(stat, Digest::SHA256.hexdigest(content))
      content if identity == expected_identity
    rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES, Errno::EPERM
      nil
    end

    def read_regular_file
      flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      File.open(@definition.target_path, flags) do |file|
        stat = file.stat
        next [ stat, nil ] unless stat.file?

        content = file.read
        [ file.stat, content ]
      end
    end

    def unsafe_file_observation(stat)
      file_observation(:unsafe, stat: stat, diagnostics: [ :unsafe_unit_path ])
    end

    def file_observation(state, stat: nil, digest: nil, diagnostics: [])
      {
        state: state,
        identity: stat && file_identity(stat, digest),
        diagnostics: diagnostics
      }
    end

    def file_identity(stat, digest)
      {
        type: stat.ftype,
        device: stat.dev,
        inode: stat.ino,
        mode: stat.mode,
        size: stat.size,
        mtime_nsec: (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec,
        mutation_snapshot: [
          stat.dev,
          stat.ino,
          stat.mode,
          stat.size,
          (stat.mtime.to_i * 1_000_000_000) + stat.mtime.nsec,
          (stat.ctime.to_i * 1_000_000_000) + stat.ctime.nsec,
          stat.nlink
        ].freeze,
        digest: digest
      }
    end

    def publish_desired(expected_identity:)
      publish_content(@definition.content, expected_identity: expected_identity)
    end

    def publish_content(content, expected_identity:)
      current = inspect_file
      identity_matches = if expected_identity
        current[:identity] == expected_identity
      else
        current[:state] == :absent
      end
      unless identity_matches
        raise TransactionJournal::Invalid, "user-service target changed before publication"
      end

      if @writer
        @writer.write(@definition.target_path, content, mode: 0o644)
        Hive::AtomicFile.fsync_directory(File.dirname(@definition.target_path))
      else
        @transaction.publish_target(
          content,
          expected_snapshot: expected_identity&.fetch(:mutation_snapshot),
          expected_digest: expected_identity&.fetch(:digest),
          expected_missing: expected_identity.nil?
        )
      end
      published = inspect_file
      unless published.dig(:identity, :digest) == Digest::SHA256.hexdigest(content)
        raise TransactionJournal::Invalid, "user-service target publication could not be verified"
      end
      published[:identity]
    rescue Transaction::Unsafe => error
      raise TransactionJournal::Invalid,
            "user-service target changed before publication: #{error.message}"
    end

    def ensure_recorded_backup(document, transaction, content)
      path = document.fetch("backup_path")
      return document unless path
      unless content && Digest::SHA256.hexdigest(content) == document.fetch("prior_digest")
        raise TransactionJournal::Invalid, "recorded user-service prior content does not match its digest"
      end
      if apply_phase_at_least?(document, :backup_stored)
        verify_recorded_backup!(document)
        return document
      end

      file = inspect_file
      unless recorded_prior_file?(file, document) || desired_file_observation?(file, document)
        raise TransactionJournal::Invalid, "user-service target changed before backup"
      end

      write_backup_exclusive(path, content)
      transaction.journal.advance(document, phase: :backup_stored)
    rescue Errno::EEXIST
      verify_recorded_backup!(document)
      transaction.journal.advance(document, phase: :backup_stored)
    end

    def verify_recorded_backup!(document)
      existing = read_backup(document.fetch("backup_path"))
      expected = document.fetch("prior_digest")
      unless existing && Digest::SHA256.hexdigest(existing) == expected
        raise TransactionJournal::Invalid,
              "recorded user-service backup does not match prior state"
      end

      true
    end

    def write_backup_exclusive(path, content)
      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      created = false
      File.open(path, flags, 0o644) do |file|
        created = true
        file.write(content)
        file.flush
        file.fsync
      end
      Hive::AtomicFile.fsync_directory(File.dirname(path))
      path
    rescue StandardError
      File.unlink(path) if created
      raise
    end

    def read_backup(path)
      flags = File::RDONLY | File::NONBLOCK
      flags |= File::NOFOLLOW if File.const_defined?(:NOFOLLOW)
      File.open(path, flags) do |file|
        stat = file.stat
        return unless stat.file? && stat.nlink == 1

        file.read
      end
    rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES, Errno::EPERM
      nil
    end

    def backup_path_for(path)
      "#{path}.bak-#{@clock.call.utc.strftime('%Y%m%dT%H%M%SZ')}"
    end

    def available_backup_path(path)
      base = backup_path_for(path)
      return base unless File.exist?(base) || File.symlink?(base)

      suffix = 2
      loop do
        candidate = "#{base}-#{suffix}"
        return candidate unless File.exist?(candidate) || File.symlink?(candidate)

        suffix += 1
      end
    end

    def home_for_target(path)
      expanded = File.expand_path(path)
      [ "/.config/systemd/user/", "/Library/LaunchAgents/" ].each do |marker|
        index = expanded.index(marker)
        return expanded[0...index] if index && index.positive?
      end

      environment_home = File.expand_path(Dir.home)
      return environment_home if expanded.start_with?(environment_home + File::SEPARATOR)

      File.dirname(expanded)
    end

    def result(kind, **kwargs)
      Result.new(kind, **kwargs)
    end

    def safe_inspect(manager: true)
      inspect_status(manager: manager)
    rescue StandardError
      nil
    end
  end
end
