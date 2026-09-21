require "hive/attempts/lost_outcome"
require "hive/attempts/repository"
require "hive/attempts/storage_status"
require "hive/task_projection/reader"
require "json"
require "psych"
require "time"

module Hive
  module Attempts
    # Two-phase publication of final attempt authority. The final row carries
    # the fixed consumer acknowledgements; no one-to-one publication ledger is
    # created or removed.
    class FinalizationMaintenance
      MAINTENANCE_INTERVAL_SEC = 60 * 60
      LOG_RETENTION_SEC = 3 * 24 * 60 * 60
      COLD_SWEEP_LIMIT = 512
      MAINTENANCE_TIME_BUDGET_SEC = 5
      MaintenanceStatus = Data.define(:attempt, :classification, :owner_status, :evidence)

      def self.runtime(store:, state_home: Hive::Paths.state_home, **options)
        require "hive/conditions/attempt_observer"
        require "hive/runtime_control_plane/dispatch_repository"
        observer = Hive::Conditions::AttemptObserver.new(store: store)
        new(
          store: store,
          condition_observer: observer,
          delivery_pending: lambda do |record|
            Hive::RuntimeControlPlane::DispatchRepository.new(
              database: store.database
            ).delivery_pending_for_attempt?(record.attempt_id)
          end,
          **options
        )
      end

      def initialize(store:, condition_observer: nil, delivery_pending: nil,
                     task_archived: nil, logger: nil,
                     monotonic_clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     maintenance_time_budget_sec: MAINTENANCE_TIME_BUDGET_SEC)
        @store = store
        @condition_observer = condition_observer
        @delivery_pending = delivery_pending
        @task_archived = task_archived
        @logger = logger
        @monotonic_clock = monotonic_clock
        @maintenance_time_budget_sec = Float(maintenance_time_budget_sec)
        raise ArgumentError, "maintenance time budget must be positive" unless @maintenance_time_budget_sec.positive?

        @last_started_at = nil
        @last_completed_at = nil
        @last_result = nil
        @last_error = nil
        @cursor_after = nil
      end

      def prepare(record)
        return false unless record.is_a?(Record) && record.final?
        return false if record.state == "lost" && !resolved_loss?(record)

        @store.prepare_publication(attempt_id: record.attempt_id)
        true
      end

      def acknowledge(record, consumer)
        return false unless @store.publication(record.attempt_id)

        @store.acknowledge_publication(record.attempt_id, consumer: consumer.to_s)
        true
      end

      # Advances only consumers that are downstream of the task-authoritative
      # terminal receipt. Every operation is idempotent so daemon
      # reconciliation can retry this boundary without another agent dispatch.
      def publish_after_journal(record)
        entry = @store.publication(record.attempt_id)
        return false unless entry&.dig("consumers", "journal") == true

        publish_indexes(record)
        acknowledge(record, :accounting)
      end

      def promote(record)
        return false unless @store.publication_complete?(record.attempt_id)

        proof = @store.fetch(record.attempt_id)
        unless proof && proof.to_h == record.to_h
          raise RepositoryError, "attempt proof does not match hot final record"
        end

        log_result = @store.log_archive.archive(record.attempt_id)
        return false if log_result == :busy

        current = @store.fetch(record.attempt_id)
        unless current&.final? && current.to_h == proof.to_h
          raise RepositoryError, "attempt changed after final proof publication"
        end

        @store.finish_publication(record.attempt_id)
        true
      end

      def finalize(record, now: Time.now.utc)
        return false unless prepare(record)
        return false unless acknowledge_journal(record, now: now)
        return false unless publish_after_journal(record)

        acknowledge(record, :dispatch) unless delivery_pending?(record)
        promote(record)
      end

      def sweep_if_due(now: Time.now.utc)
        maintain(now) { 0 }
      end

      def sweep_logs(now: Time.now.utc)
        deleted = 0
        errors = 0
        examined = 0
        last_examined = nil
        deadline = @monotonic_clock.call + @maintenance_time_budget_sec
        page = @store.log_archive.cold_attempt_ids_page(
          cursor: { "after" => @cursor_after },
          limit: COLD_SWEEP_LIMIT
        )
        page.attempt_ids.each do |attempt_id|
          break if @monotonic_clock.call >= deadline

          last_examined = attempt_id
          examined += 1
          begin
            record = @store.fetch(attempt_id)
            next unless record&.final?
            next if recovery_pinned?(record)
            next unless retention_expired?(record, now: now) ||
                        task_archived?(record)

            deleted += 1 if @store.log_archive.expire(attempt_id, now: now) == :expired
          rescue StandardError => error
            errors += 1
            record_maintenance_error(error, now: now, attempt_id: attempt_id)
          end
        end
        @cursor_after = last_examined || page.cursor.fetch("after") if
          last_examined || page.attempt_ids.empty?
        { deleted: deleted, cold_examined: examined, errors: errors }
      end

      def storage_snapshot(hot_count:, invalid_hot_count:)
        diagnosis = @store.database.diagnostics
        database_error = !diagnosis.ok? && {
          "operation" => "status", "class" => diagnosis.error&.class&.name || "IntegrityError"
        }
        maintenance_error = @last_error
        error = maintenance_error || database_error
        status = StorageStatus.unknown
        status["status"] = error ? "degraded" : (@last_started_at ? "healthy" : "unknown")
        status["layout"]["migration"] = diagnosis.ok? ? "complete" : "failed"
        status["hot"] = { "records" => hot_count, "invalid" => invalid_hot_count }
        status["maintenance"].merge!(
          "last_started_at" => timestamp(@last_started_at),
          "last_completed_at" => timestamp(@last_completed_at),
          "last_result" => @last_result
        )
        status["last_error"] = error
        status["degraded_reason"] = maintenance_error ? "maintenance_failed" :
          (database_error && "database_unhealthy")
        status
      rescue RuntimeControlPlane::Error
        StorageStatus.unknown.merge(
          "status" => "degraded", "last_error" => { "operation" => "status", "class" => "IntegrityError" },
          "degraded_reason" => "database_unhealthy"
        )
      end

      private

      def maintain(now)
        now = normalize_time(now)
        empty = { ran: false, promoted: 0, deleted: 0, cold_examined: 0, errors: 0 }
        return empty unless maintenance_due?(now)

        @last_started_at = now
        @last_error = nil
        result = sweep_logs(now: now).merge(ran: true, promoted: yield)
        @last_completed_at = now
        @last_result = result.slice(:promoted, :deleted, :cold_examined, :errors)
          .transform_keys(&:to_s)
        result
      rescue StandardError => error
        record_maintenance_error(error, now: now)
        raise
      end

      def acknowledge_journal(record, now:)
        return false unless @condition_observer&.respond_to?(:observe)

        status = MaintenanceStatus.new(
          attempt: record,
          classification: record.state == "terminal" ? :terminal : :already_lost,
          owner_status: :not_applicable,
          evidence: {}
        )
        result = @condition_observer.observe(status, now: now)
        return false unless %i[delivered acknowledged not_applicable].include?(result)

        acknowledge(record, :journal)
      end

      def delivery_pending?(record)
        return true unless @delivery_pending

        @delivery_pending.call(record) == true
      rescue Hive::Error, SystemCallError, IOError
        true
      end

      def maintenance_due?(now)
        !@last_started_at || now >= @last_started_at + MAINTENANCE_INTERVAL_SEC
      end

      def record_maintenance_error(error, now:, attempt_id: nil)
        @last_error = {
          "operation" => "maintenance", "class" => error.class.name,
          "observed_at" => timestamp(normalize_time(now))
        }
        @last_error["attempt_id"] = attempt_id.to_s if attempt_id
        @logger&.event(
          :attempt_maintenance_failed,
          error_class: error.class.name, attempt_id: attempt_id
        )
      rescue StandardError
        nil
      end

      def normalize_time(value)
        value.respond_to?(:utc) ? value.utc : Time.iso8601(value.to_s).utc
      end

      def timestamp(value) = value && Record.iso8601(value)

      def recovery_pinned?(record)
        publication = @store.publication(record.attempt_id)
        return false unless publication
        return true unless publication.is_a?(Hash)

        publication.fetch("promoted") != true
      rescue RepositoryError, KeyError
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
        bounded = Hive::TaskProjection::Reader.new(
          task_folder: task.folder, task: task
        ).read_routine(marker: marker)
        return false unless bounded.current?

        Hive::TaskAction.for(
          task, marker, config: config, projection: bounded.projection
        ).key ==
          Hive::Schemas::TaskActionKind::ARCHIVED
      rescue Hive::Error, KeyError, Psych::Exception, SystemCallError, IOError
        false
      end

      def publish_indexes(record)
        if record.state == "terminal"
          if record.receipt.fetch("exit_status") == Hive::ExitCodes::TEMPFAIL
            @store.refund_tempfail(record)
          end
        else
          # A loss that never started spent nothing, so it must not spend a
          # daily slot either — otherwise failed launches exhaust the budget
          # that real runs need.
          @store.refund_unstarted(record) if record["started_at"].nil?
        end
      end

      def resolved_loss?(record)
        outcome = LostOutcomeTransition.new(store: @store).fetch(record.attempt_id)
        LostOutcomeTransition::FINAL_PHASES.include?(outcome&.fetch("phase", nil)) &&
          LostOutcomeTransition::SAFE_CLEANUPS.include?(outcome["cleanup"])
      rescue RepositoryError
        false
      end
    end
  end
end
