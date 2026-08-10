require "hive/attempts/lost_outcome"
require "hive/attempts/store"
require "json"
require "psych"
require "time"

module Hive
  module Attempts
    # Two-phase publication of final attempt authority. Proof, decision
    # indexes, and the bounded consumer ledger are durable before any
    # downstream acknowledgement can permit removal from the hot scan.
    class FinalizationMaintenance
      TERMINAL_CONSUMERS = %w[accounting journal request_delivery].freeze
      LOST_CONSUMERS = (TERMINAL_CONSUMERS + [ "loss" ]).freeze
      SAFE_LOST_CLEANUPS = %w[absent terminated no_worker].freeze
      MAINTENANCE_INTERVAL_SEC = 60 * 60
      LOG_RETENTION_SEC = 3 * 24 * 60 * 60
      MaintenanceStatus = Data.define(:attempt, :classification, :owner_status, :evidence)

      def initialize(store:, condition_observer: nil, delivery_pending: nil,
                     task_archived: nil, logger: nil)
        @store = store
        @condition_observer = condition_observer
        @delivery_pending = delivery_pending
        @task_archived = task_archived
        @logger = logger
        @storage_health = store.storage_health
      end

      def prepare(record)
        return false unless record.is_a?(Record) && record.final?
        return false if record.state == "lost" && !resolved_loss?(record)

        @store.permanent_proofs.publish(record)
        publish_indexes(record)
        pending.create(
          attempt_id: record.attempt_id,
          consumers: record.state == "lost" ? LOST_CONSUMERS : TERMINAL_CONSUMERS
        )
        pending.acknowledge(record.attempt_id, consumer: "accounting")
        pending.acknowledge(record.attempt_id, consumer: "loss") if record.state == "lost"
        true
      end

      def acknowledge(record, consumer)
        return false unless pending.fetch(record.attempt_id)

        pending.acknowledge(record.attempt_id, consumer: consumer.to_s)
        true
      end

      def promote(record)
        return false unless pending.complete?(record.attempt_id)

        proof = @store.permanent_proofs.fetch(record.attempt_id)
        unless proof && proof.to_h == record.to_h
          raise StoreError, "attempt proof does not match hot final record"
        end

        log_result = @store.log_archive.archive(record.attempt_id)
        return false if log_result == :busy

        @store.with_admission_lock do
          current = @store.fetch_hot(record.attempt_id)
          return true unless current
          unless current.final? && current.to_h == proof.to_h
            raise StoreError, "hot attempt changed after final proof publication"
          end

          pending.remove_complete(record.attempt_id)
          @store.decision_index.release_live(attempt_id: record.attempt_id)
          @store.remove_hot_final(current)
        end
        true
      end

      def run_if_due(now: Time.now.utc)
        return { ran: false, promoted: 0, deleted: 0, cold_examined: 0 } unless claim_due(now)

        promoted = 0
        @store.scan.records.each do |record|
          next unless prepare(record)

          acknowledge_journal(record, now: now)
          acknowledge(record, :request_delivery) unless delivery_pending?(record)
          promoted += 1 if promote(record)
        end
        result = sweep_logs(now: now).merge(ran: true, promoted: promoted)
        @storage_health.complete_maintenance(now: now, result: result)
        result
      rescue StandardError => error
        @storage_health.fail_maintenance(error: error, now: now)
        raise
      end

      def sweep_if_due(now: Time.now.utc)
        return { ran: false, promoted: 0, deleted: 0, cold_examined: 0 } unless claim_due(now)

        result = sweep_logs(now: now).merge(ran: true, promoted: 0)
        @storage_health.complete_maintenance(now: now, result: result)
        result
      rescue StandardError => error
        @storage_health.fail_maintenance(error: error, now: now)
        raise
      end

      def sweep_logs(now: Time.now.utc)
        deleted = 0
        cold_examined = 0
        @store.log_archive.each_cold_attempt_id do |attempt_id|
          cold_examined += 1
          record = @store.fetch(attempt_id)
          next unless record&.final?
          next if recovery_pinned?(record)
          next unless task_archived?(record) || retention_expired?(record, now: now)

          deleted += 1 if @store.log_archive.expire(attempt_id, now: now) == :expired
        end
        { deleted: deleted, cold_examined: cold_examined }
      end

      private

      def acknowledge_journal(record, now:)
        return unless @condition_observer&.respond_to?(:observe)

        status = MaintenanceStatus.new(
          attempt: record,
          classification: record.state == "terminal" ? :terminal : :already_lost,
          owner_status: :not_applicable,
          evidence: {}
        )
        result = @condition_observer.observe(status, now: now)
        acknowledge(record, :journal) if %i[delivered acknowledged not_applicable].include?(result)
      end

      def delivery_pending?(record)
        return true unless @delivery_pending

        @delivery_pending.call(record) == true
      rescue Hive::Error, SystemCallError, IOError
        true
      end

      def claim_due(now)
        @storage_health.claim_maintenance(
          now: now,
          interval_sec: MAINTENANCE_INTERVAL_SEC
        )
      end

      def recovery_pinned?(record)
        hot = @store.fetch_hot(record.attempt_id)
        return false unless hot

        !pending.complete?(record.attempt_id)
      rescue StoreError
        true
      end

      def retention_expired?(record, now:)
        ended_at = Time.iso8601(record["ended_at"].to_s)
        now.utc >= ended_at + LOG_RETENTION_SEC
      rescue ArgumentError, TypeError
        false
      end

      def task_archived?(record)
        return @task_archived.call(record) == true if @task_archived

        require "hive/config"
        require "hive/markers"
        require "hive/task"
        require "hive/task_action"
        project = Hive::Config.find_project(record["project"])
        return false unless project

        candidates = Dir.glob(
          File.join(project.fetch("hive_state_path"), "stages", "*", record["task_slug"])
        ).filter_map do |folder|
          task = Hive::Task.new(folder)
          next if record["task_id"] && task.id.to_s != record["task_id"].to_s

          task
        rescue Hive::Error, SystemCallError, IOError
          nil
        end
        return false unless candidates.one?

        task = candidates.first
        marker = Hive::Markers.current(task.state_file)
        config = Hive::Config.load(task.project_root)
        Hive::TaskAction.for(task, marker, config: config).key ==
          Hive::Schemas::TaskActionKind::ARCHIVED
      rescue Hive::Error, KeyError, Psych::Exception, SystemCallError, IOError
        false
      end

      def pending
        @pending ||= @store.pending_finalizations
      end

      def publish_indexes(record)
        index = @store.decision_index
        index.record_acceptance(record)
        if record.state == "terminal"
          index.record_terminal(record)
          if record.receipt.fetch("exit_status") == Hive::ExitCodes::TEMPFAIL
            index.refund_tempfail(record)
          end
        else
          index.record_unresolved_loss(record)
          successor = resolved_loss_successor(record)
          index.record_successor(successor)
        end
      end

      def resolved_loss?(record)
        !resolved_loss_successor(record).nil?
      rescue StoreError
        false
      end

      def resolved_loss_successor(record)
        outcome = LostOutcomeStore.new(store: @store).fetch(record.attempt_id)
        return nil unless outcome&.fetch("status", nil) == "successor_dispatched"
        return nil unless SAFE_LOST_CLEANUPS.include?(outcome["cleanup"])

        successor_id = outcome["successor_attempt_id"].to_s
        return nil if successor_id.empty? || successor_id == record.attempt_id
        indexed_id = @store.decision_index.successor_attempt_id(
          predecessor_attempt_id: record.attempt_id
        )
        return nil unless indexed_id == successor_id

        successor = @store.fetch(successor_id)
        return nil unless successor && successor["predecessor_attempt_id"] == record.attempt_id
        return nil unless successor.task_generation == record.task_generation
        return nil unless successor.subject == record.subject

        successor
      end
    end
  end
end
