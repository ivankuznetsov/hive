require "date"
require "hive/attempts/lost_outcome"
require "hive/attempts/store"

module Hive
  module Attempts
    # Rebuildable capacity view derived from the durable attempt history.
    # Invalid records reserve a global slot fail-closed but cannot safely be
    # attributed to a project or task.
    CapacitySnapshot = Data.define(
      :global_count, :per_project, :per_task, :daily_counts,
      :reserved_attempt_ids, :invalid_count
    ) do
      def self.build(store:, scan: nil, now: Time.now, daily_counts: nil)
        scan ||= store.scan
        outcome_store = LostOutcomeStore.new(store: store)
        reserved = scan.records.select do |record|
          reserves_capacity?(record, outcome_store: outcome_store)
        end
        per_project = Hash.new(0)
        per_task = Hash.new(0)
        reserved.each do |record|
          per_project[record["project"]] += 1
          per_task[[ record["project"], record["task_slug"] ]] += 1
        end

        daily = daily_counts || begin
          counts = Hash.new(0)
          scan.records.each do |record|
            receipt = record.receipt
            next if receipt && receipt["exit_status"] == Hive::ExitCodes::TEMPFAIL

            date = Time.iso8601(record["accepted_at"]).utc.to_date
            counts[[ record["project"], date ]] += 1
          rescue ArgumentError
            # Record validation already checked the timestamp. Preserve the
            # fail-closed global reservation if a future schema changes it.
            next
          end
          counts
        end

        invalid_count = scan.invalid_records.size
        new(
          global_count: reserved.size + invalid_count,
          per_project: per_project.to_h.freeze,
          per_task: per_task.to_h.freeze,
          daily_counts: daily.to_h.freeze,
          reserved_attempt_ids: reserved.map(&:attempt_id).freeze,
          invalid_count: invalid_count
        )
      end

      def self.build_from_live_reservations(scan:, reservations:, daily_counts:)
        per_project = Hash.new(0)
        per_task = Hash.new(0)
        reservations.each_value do |reservation|
          project = reservation.fetch("project")
          task_slug = reservation.fetch("task_slug")
          per_project[project] += 1
          per_task[[ project, task_slug ]] += 1
        end
        reservation_ids = reservations.keys
        invalid_ids = scan.invalid_records.filter_map do |invalid|
          basename = File.basename(invalid.path.to_s)
          basename.delete_suffix(".json") if basename.end_with?(".json")
        end
        unindexed_invalid_count = invalid_ids.count do |attempt_id|
          !reservations.key?(attempt_id)
        end

        new(
          global_count: reservations.size + unindexed_invalid_count,
          per_project: per_project.to_h.freeze,
          per_task: per_task.to_h.freeze,
          daily_counts: daily_counts.freeze,
          reserved_attempt_ids: reservation_ids.freeze,
          invalid_count: scan.invalid_records.size
        )
      end

      def self.reserves_capacity?(record, outcome_store:)
        record.live? || lost_worker_reserves_capacity?(record, outcome_store)
      end

      def self.lost_worker_reserves_capacity?(record, outcome_store)
        return false unless record.respond_to?(:state) && record.state == "lost" && record.worker

        outcome = outcome_store.fetch(record.attempt_id)
        !LostOutcomeStore::SAFE_CLEANUPS.include?(outcome&.fetch("cleanup", nil))
      rescue StoreError
        true
      end
      private_class_method :lost_worker_reserves_capacity?

      def project_count(project) = per_project.fetch(project, 0)
      def task_count(project:, task_slug:) = per_task.fetch([ project, task_slug ], 0)
      def daily_count(project, date) = daily_counts.fetch([ project, date ], 0)
      def task_reserved?(project:, task_slug:) = task_count(project: project, task_slug: task_slug).positive?

      def at_limit?(project:, task_slug:, date:, max_global:, max_per_project:, max_daily:)
        global_count >= max_global ||
          project_count(project) >= max_per_project ||
          task_reserved?(project: project, task_slug: task_slug) ||
          daily_count(project, date) >= max_daily
      end
    end

    # One daemon-tick view of bounded hot records. The initial scan never
    # changes; admissions add an in-memory delta, while each admission-lock
    # decision point-refreshes known hot IDs and repairs the point indexes.
    # It deliberately uses fetch_hot so ordinary scheduler work never opens
    # permanent proof storage.
    class AdmissionView
      attr_reader :hot_scan

      def initialize(store:, hot_scan:)
        @store = store
        @hot_scan = hot_scan
        @records = hot_scan.records.to_h { |record| [ record.attempt_id, record ] }
        @indexed_versions = {}
        synchronize_indexes!(@records.values)
      end

      def records
        refresh_known_records!
        synchronize_indexes!(@records.values)
        @records.values.freeze
      end

      # Call only while the store's host-wide admission lock is held. The
      # point-addressed live-capacity cell is reconciled here so a daemon tick
      # can retain its one hot scan while still observing admissions made by
      # another Store instance after that scan.
      def refresh_for_admission
        reservations = mutable_live_reservations
        merge_observed_reservations!(reservations, @records.values)
        refresh_known_records!(unreadable: :forget)
        hydrate_reserved_records!(reservations)
        merge_observed_reservations!(reservations, @records.values)
        release_converged_reservations!(reservations)
        decision_index.replace_live_reservations(reservations)
        synchronize_indexes!(@records.values)
        @records.values.freeze
      end

      def capacity(now:, records: nil)
        current = records || self.records
        CapacitySnapshot.build_from_live_reservations(
          scan: Scan.new(
            records: current.freeze,
            invalid_records: hot_scan.invalid_records
          ),
          reservations: decision_index.live_reservations,
          daily_counts: decision_index.daily_counts(date: now.utc.to_date)
        )
      end

      # These mutations share the admission lock held by Dispatcher#admit.
      def reserve_live(attempt_id:, project:, task_slug:)
        decision_index.reserve_live(
          attempt_id: attempt_id, project: project, task_slug: task_slug
        )
      end

      def confirm_live(record)
        decision_index.confirm_live(
          attempt_id: record.attempt_id,
          project: record["project"],
          task_slug: record["task_slug"]
        )
      end

      def record(record)
        @records[record.attempt_id] = record
        synchronize_indexes!([ record ])
        record
      end

      def find(attempt_id)
        return nil if attempt_id.to_s.empty?

        record = @store.fetch(attempt_id)
        return self.record(record) if record

        @records.delete(attempt_id)
        nil
      end

      def terminal_attempt(request_id:)
        find(decision_index.terminal_attempt_id(request_id: request_id))
      end

      def successful_attempt(task_generation:, subject:)
        find(
          decision_index.successful_attempt_id(
            task_generation: task_generation, subject: subject
          )
        )
      end

      def unresolved_loss(task_generation:, subject:)
        find(
          decision_index.unresolved_loss_attempt_id(
            task_generation: task_generation, subject: subject
          )
        )
      end

      def successor(predecessor_attempt_id:)
        find(
          decision_index.successor_attempt_id(
            predecessor_attempt_id: predecessor_attempt_id
          )
        )
      end

      private

      def decision_index
        @decision_index ||= @store.decision_index
      end

      def outcome_store
        @outcome_store ||= LostOutcomeStore.new(store: @store)
      end

      def refresh_known_records!(unreadable: :raise)
        @records.keys.each do |attempt_id|
          record = @store.fetch_hot(attempt_id)
          record ? @records[attempt_id] = record : @records.delete(attempt_id)
        rescue StoreError
          raise if unreadable == :raise

          # The live-capacity cell was synchronized from the last valid
          # observation before this refresh, so forgetting the unreadable
          # semantic record remains capacity-fail-closed.
          @records.delete(attempt_id)
        end
      end

      def mutable_live_reservations
        decision_index.live_reservations.transform_values(&:dup)
      end

      def merge_observed_reservations!(reservations, records)
        records.each do |record|
          if CapacitySnapshot.reserves_capacity?(record, outcome_store: outcome_store)
            reservations[record.attempt_id] = {
              "project" => record["project"],
              "task_slug" => record["task_slug"],
              "phase" => "active"
            }
          else
            reservations.delete(record.attempt_id)
          end
        end
      end

      def hydrate_reserved_records!(reservations)
        reservations.each_key do |attempt_id|
          next if @records.key?(attempt_id)

          record = @store.fetch_hot(attempt_id)
          @records[attempt_id] = record if record
        rescue StoreError
          # Keep the reservation fail-closed; the invalid hot record remains
          # represented by the reservation even though it cannot be indexed.
          next
        end
      end

      def release_converged_reservations!(reservations)
        reservations.delete_if do |attempt_id, reservation|
          next false if @records.key?(attempt_id)
          next true if reservation.fetch("phase") == "pending"

          proof = @store.fetch(attempt_id)
          if proof&.state == "terminal"
            synchronize_indexes!([ proof ])
            true
          else
            false
          end
        rescue StoreError
          # Missing or unreadable active state remains capacity-fail-closed.
          false
        end
      end

      def synchronize_indexes!(records)
        records.each do |record|
          version = [ record.lease_version, record.state ]
          next if @indexed_versions[record.attempt_id] == version

          decision_index.record_acceptance(record)
          if record.state == "lost"
            successor_id = decision_index.successor_attempt_id(
              predecessor_attempt_id: record.attempt_id
            )
            decision_index.record_unresolved_loss(record) unless successor_id
          end
          if record["predecessor_attempt_id"]
            decision_index.record_successor(record)
          end
          if record.state == "terminal"
            decision_index.record_terminal(record)
            if record.receipt["exit_status"] == Hive::ExitCodes::TEMPFAIL
              decision_index.refund_tempfail(record)
            end
          end
          @indexed_versions[record.attempt_id] = version
        end
      end
    end
  end
end
