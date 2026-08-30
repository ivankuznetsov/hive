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

    def initialize(definition:, runner: nil, query_available: false, manager_available: false,
                   status_reader: nil, launchd_running_via_list: false,
                   writer: Hive::AtomicFile, clock: -> { Time.now.utc },
                   event_handler: nil, home: nil,
                   lock_wait: Transaction::LOCK_WAIT_SEC, legacy_takeover: nil)
      @definition = definition
      @runner = runner || ->(argv) { system(*argv, out: File::NULL) }
      @writer = writer
      @clock = clock
      @event_handler = event_handler
      @legacy_takeover = legacy_takeover
      @manager = Manager.new(
        definition: definition,
        runner: @runner,
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

    def plan(autostart:, force: false)
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
        force: force
      )
    end

    def plan_remove
      status = inspect_status(manager: false)
      manager_observed = !%i[absent unsafe unreadable].include?(status.content_state)
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

      @transaction.with_lock do |transaction|
        if (recovery = reconcile_pending(transaction))
          return recovery unless recovery.success?
          plan = plan_remove
        end
        remove_current(plan, transaction)
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
        diagnostics: manager_inspection.diagnostics + file.fetch(:diagnostics)
      )
    end

    def remove_current(plan, transaction)
      current = inspect_status(manager: plan.manager_observed)
      return stale_result(:remove, current) unless current.observation_key == plan.expected_observation
      if current.content_state == :absent
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

      prior_content = bound_file_content(current.file_identity)
      return stale_result(:remove, inspect_status(manager: plan.manager_observed)) unless prior_content

      document = transaction.journal.prepare(
        operation: :remove,
        prior_content: prior_content,
        prior_digest: current.file_identity&.fetch(:digest),
        prior_enabled: current.enabled?,
        prior_running: current.running?,
        desired_digest: nil,
        backup_path: nil,
        manager_intent: :disable,
        result_kind: :removed,
        autostart: true
      )
      transition_event(:after_removal_prepared)
      disabled = @manager.disable
      after_disable = inspect_status(manager: true)
      unless disabled.ok || (after_disable.manager_available? && !after_disable.enabled? && !after_disable.running?)
        return result(
          :failed,
          operation: :remove,
          final_status: after_disable,
          diagnostics: disabled.diagnostics + [ :recovery_pending ]
        )
      end
      document = transaction.journal.advance(document, phase: :manager_disabled)
      transition_event(:after_manager_disabled)

      after_disable = inspect_file
      unless after_disable[:identity] == current.file_identity
        return result(
          :failed,
          operation: :remove,
          final_status: inspect_status(manager: true),
          diagnostics: %i[stale_after_manager_change recovery_pending]
        )
      end

      if (error = unlink_target)
        return Result.new(
          :failed,
          operation: :remove,
          final_status: safe_inspect(manager: true),
          diagnostics: %i[remove_failed recovery_pending],
          error: error
        )
      end
      document = transaction.journal.advance(document, phase: :unit_removed)
      transition_event(:after_unit_removed)

      reload = @manager.reload_after_remove
      final_status = inspect_status(manager: true)
      verified = reload.ok && final_status.content_state == :absent &&
                 (!final_status.manager_available? || (!final_status.enabled? && !final_status.running?))
      unless verified
        return result(
          :failed,
          operation: :remove,
          final_status: final_status,
          diagnostics: reload.diagnostics + [ :recovery_pending ]
        )
      end

      transaction.journal.advance(document, phase: :removal_verified)
      transition_event(:after_removal_verified)
      transaction.clear_after_verified_removal
      result(:removed, operation: :remove, final_status: final_status, diagnostics: reload.diagnostics)
    end

    def unlink_target
      File.unlink(@definition.target_path)
      nil
    rescue Errno::ENOENT
      # The desired end state was reached concurrently. The manager still
      # needs its post-remove reload.
      nil
    rescue StandardError => error
      error
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
      if receipt_satisfies?(receipt, desired_digest: desired_digest, plan: plan, status: current)
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
          plan.action == :replace || legacy_match ? :restart : :enable
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
        autostart: plan.autostart
      )
      transition_event(:after_journal_prepared)

      if backup_path
        document = ensure_recorded_backup(document, transaction, backup_content)
        transition_event(:after_backup_stored)
      end

      if plan.action != :noop
        begin
          write(@definition.target_path, @definition.content)
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
      document = transaction.journal.read
      return nil unless document

      if document.fetch("operation") == "remove"
        return recover_removal(document, transaction)
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
      if file[:state] == :matching
        unless transaction.journal.activation_recorded?(document) ||
               transaction.journal.phase?(document, :unit_published)
          document = transaction.journal.advance(document, phase: :unit_published)
        end
      else
        prior_matches = if document.fetch("prior_digest")
          file.dig(:identity, :digest) == document.fetch("prior_digest")
        else
          file[:state] == :absent
        end
        unless prior_matches
          return result(
            :failed,
            final_status: safe_inspect(manager: true),
            diagnostics: %i[invalid_recovery_state recovery_pending]
          )
        end

        prior_content = transaction.journal.prior_content(document)
        document = ensure_recorded_backup(document, transaction, prior_content)
        write(@definition.target_path, @definition.content)
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
        unless final_status.content_state == :matching
          return result(
            :failed,
            backup_path: backup_path,
            final_status: final_status,
            diagnostics: diagnostics + %i[verification_failed recovery_pending]
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
      unless status.manager_available?
        return result(
          :failed,
          backup_path: backup_path,
          restarted: intent == "restart",
          final_status: status,
          diagnostics: diagnostics + status.diagnostics + [ :recovery_pending ]
        )
      end

      action = nil
      phase_proves_activation = transaction.journal.activation_recorded?(document)
      unless replay && phase_proves_activation && desired_endpoint?(status)
        if intent == "takeover" && !status.running?
          unless @legacy_takeover
            return result(
              :failed,
              backup_path: backup_path,
              final_status: status,
              diagnostics: diagnostics + %i[legacy_takeover_failed recovery_pending]
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
            return result(
              :failed,
              backup_path: backup_path,
              final_status: safe_inspect(manager: true),
              diagnostics: diagnostics + %i[legacy_takeover_failed recovery_pending]
            )
          end
        end

        action = @manager.apply_intent(intent || :enable)
        document = transaction.journal.advance(document, phase: :activated)
        transition_event(:after_activated)
        status = inspect_status(manager: true)
        diagnostics.concat(action.diagnostics)
      end

      if desired_endpoint?(status)
        diagnostics << :manager_effect_verified if action && !action.ok
        return finalize_apply(
          document, transaction,
          mode: :managed,
          kind: document.fetch("result_kind").to_sym,
          status: status,
          diagnostics: diagnostics,
          restarted: intent == "restart"
        )
      end

      if status.manager_availability != :available
        return result(
          :failed,
          backup_path: backup_path,
          restarted: intent == "restart",
          final_status: status,
          diagnostics: diagnostics + [ :recovery_pending ]
        )
      end

      rollback_apply(document, transaction, diagnostics: diagnostics)
    end

    def finalize_apply(document, transaction, mode:, kind:, status:, diagnostics:, restarted: false)
      unless transaction.journal.phase?(document, :committed)
        unless transaction.journal.phase?(document, :verified)
          document = transaction.journal.advance(document, phase: :verified)
          transition_event(:after_verified)
        end
        document = transaction.journal.advance(document, phase: :committed)
        transition_event(:after_committed)
      end
      transaction.receipt.write(
        digest: document.fetch("desired_digest"),
        mode: mode,
        manager_intent: document.fetch("manager_intent")
      )
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
        prior_content = transaction.journal.prior_content(document)
        if prior_content
          write(@definition.target_path, prior_content)
        else
          File.unlink(@definition.target_path) unless inspect_file[:state] == :absent
        end
        document = transaction.journal.advance(document, phase: :prior_file_restored)
        transition_event(:after_prior_file_restored)
      end

      manager = Manager::Action.new(ok: true, restarted: false, diagnostics: [])
      if transaction.journal.phase?(document, :prior_file_restored)
        manager = if document.fetch("autostart") && document.fetch("manager_intent")
          @manager.restore(
            prior_enabled: document.fetch("prior_enabled"),
            prior_running: document.fetch("prior_running")
          )
        else
          manager
        end
        document = transaction.journal.advance(document, phase: :prior_manager_restored)
        transition_event(:after_prior_manager_restored)
      end
      status = inspect_status(manager: document.fetch("autostart"))
      prior_file_verified = if document.fetch("prior_digest")
        status.file_identity&.fetch(:digest) == document.fetch("prior_digest")
      else
        status.content_state == :absent
      end
      prior_manager_verified = !document.fetch("autostart") ||
        (status.manager_available? &&
         status.enabled? == document.fetch("prior_enabled") &&
         status.running? == document.fetch("prior_running"))
      unless manager.ok && prior_file_verified && prior_manager_verified
        return result(
          :failed,
          backup_path: document.fetch("backup_path"),
          restarted: document.fetch("manager_intent") == "restart",
          final_status: status,
          diagnostics: diagnostics + manager.diagnostics + [ :recovery_pending ]
        )
      end

      unless transaction.journal.phase?(document, :prior_verified)
        document = transaction.journal.advance(document, phase: :prior_verified)
        transition_event(:after_prior_verified)
      end
      transaction.receipt.delete
      transaction.journal.delete
      result(
        :failed,
        backup_path: document.fetch("backup_path"),
        restarted: document.fetch("manager_intent") == "restart",
        final_status: status,
        diagnostics: diagnostics + manager.diagnostics + [ :prior_state_restored ]
      )
    end

    def recover_removal(document, transaction)
      file = inspect_file
      prior_matches = file[:state] == :absent ||
                      file.dig(:identity, :digest) == document.fetch("prior_digest")
      unless prior_matches
        return result(
          :failed,
          operation: :remove,
          final_status: safe_inspect(manager: true),
          diagnostics: %i[invalid_recovery_state recovery_pending]
        )
      end

      unless file[:state] == :absent
        disabled = @manager.disable
        status = inspect_status(manager: true)
        unless disabled.ok || (status.manager_available? && !status.enabled? && !status.running?)
          return result(
            :failed,
            operation: :remove,
            final_status: status,
            diagnostics: disabled.diagnostics + [ :recovery_pending ]
          )
        end
        document = transaction.journal.advance(document, phase: :manager_disabled)
        File.unlink(@definition.target_path)
        document = transaction.journal.advance(document, phase: :unit_removed)
      end

      reload = @manager.reload_after_remove
      status = inspect_status(manager: true)
      unless reload.ok && status.content_state == :absent &&
             (!status.manager_available? || (!status.enabled? && !status.running?))
        return result(
          :failed,
          operation: :remove,
          final_status: status,
          diagnostics: reload.diagnostics + [ :recovery_pending ]
        )
      end

      transaction.journal.advance(document, phase: :removal_verified)
      transaction.clear_after_verified_removal
      result(:removed, operation: :remove, final_status: status, diagnostics: [ :recovery_resumed ])
    end

    def receipt_satisfies?(receipt, desired_digest:, plan:, status:)
      return false unless receipt && receipt.fetch("desired_digest") == desired_digest
      return false unless status.content_state == :matching
      return true unless plan.autostart

      case receipt.fetch("mode")
      when "managed"
        status.manager_available? && status.enabled? && status.running?
      when "unsupported_autostart"
        status.manager_availability == :conclusively_absent
      else
        false
      end
    end

    def desired_endpoint?(status)
      status.content_state == :matching && status.manager_available? &&
        status.enabled? && status.running?
    end

    def lifecycle(operation)
      return result(:unsupported, operation: operation, final_status: inspect) unless @transaction

      @transaction.with_lock do |transaction|
        if (recovery = reconcile_pending(transaction))
          return recovery unless recovery.success?
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
        action = @manager.public_send(operation)
        after = inspect_status(manager: true)
        expected_running = operation != :stop
        verified = action.ok && after.running? == expected_running
        result(
          verified ? :unchanged : :failed,
          operation: operation,
          restarted: operation == :restart || operation == :takeover,
          final_status: after,
          diagnostics: action.diagnostics + (verified ? [] : [ :manager_action_unverified ])
        )
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
        expected_manager_observed =
          !%i[absent unsafe unreadable].include?(plan.status.content_state)
        plan.action == expected_action &&
          plan.manager_observed == expected_manager_observed &&
          !plan.autostart &&
          !plan.force
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
        digest: digest
      }
    end

    def write(path, content)
      @writer.write(path, content, mode: 0o644)
    end

    def ensure_recorded_backup(document, transaction, content)
      path = document.fetch("backup_path")
      return document unless path
      return document if transaction.journal.phase?(document, :backup_stored)

      write_backup_exclusive(path, content)
      transaction.journal.advance(document, phase: :backup_stored)
    rescue Errno::EEXIST
      existing = read_backup(path)
      expected = document.fetch("prior_digest")
      unless existing && Digest::SHA256.hexdigest(existing) == expected
        raise TransactionJournal::Invalid, "recorded user-service backup does not match prior state"
      end
      transaction.journal.advance(document, phase: :backup_stored)
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
