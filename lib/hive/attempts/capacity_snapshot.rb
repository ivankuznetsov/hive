require "date"
require "hive/attempts/repository"

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
        reservations = store.live_reservations
        per_project = Hash.new(0)
        per_task = Hash.new(0)
        reservations.each_value do |reservation|
          project = reservation.fetch("project")
          task_slug = reservation.fetch("task_slug")
          per_project[project] += 1
          per_task[[ project, task_slug ]] += 1
        end

        daily = daily_counts || store.daily_counts(date: now.utc.to_date)
        reserved_ids = reservations.keys.freeze
        unreserved_invalid = scan.invalid_records.count do |invalid|
          !reservations.key?(invalid.path.to_s.split(":").last)
        end
        new(
          global_count: reservations.size + unreserved_invalid,
          per_project: per_project.to_h.freeze,
          per_task: per_task.to_h.freeze,
          daily_counts: daily.to_h.freeze,
          reserved_attempt_ids: reserved_ids,
          invalid_count: scan.invalid_records.size
        )
      end

      def project_count(project) = per_project.fetch(project, 0)
      def task_count(project:, task_slug:) = per_task.fetch([ project, task_slug ], 0)
      def daily_count(project, date) = daily_counts.fetch([ project, date ], 0)
      def task_reserved?(project:, task_slug:) = task_count(project: project, task_slug: task_slug).positive?

      # Explicit routing shares one provider-account cap across projects. The
      # attempt ledger remains the semaphore: routed records carry their exact
      # account, while a legacy record contributes only when it maps
      # unambiguously to the configured default binding for its adapter.
      def provider_account_capacity(policy:, records:)
        accounts = policy.account_policy
        counts = accounts.keys.to_h { |account_id| [ account_id, 0 ] }
        reserved = reserved_attempt_ids.to_h { |attempt_id| [ attempt_id, true ] }
        default_accounts = accounts.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(id, entry), result|
          if entry.fetch("launch_binding") == "default"
            result[entry.fetch("adapter")] << id
          end
        end

        Array(records).each do |record|
          next unless reserved[record.attempt_id]

          routing = record["routing"]
          account_id = if routing.is_a?(Hash) && routing["mode"] == "explicit"
            routing.dig("route", "provider_account_id")
          else
            candidates = default_accounts[record["provider"]]
            candidates.one? ? candidates.first : nil
          end
          counts[account_id] += 1 if counts.key?(account_id)
        end

        counts.to_h do |account_id, observed|
          maximum = Integer(accounts.fetch(account_id).fetch("max_concurrent"))
          [ account_id, { "observed" => observed, "max" => maximum }.freeze ]
        end.freeze
      end

      def at_limit?(project:, task_slug:, date:, max_global:, max_per_project:, max_daily:)
        global_count >= max_global ||
          project_count(project) >= max_per_project ||
          task_reserved?(project: project, task_slug: task_slug) ||
          daily_count(project, date) >= max_daily
      end
    end

    # A bounded attempt view for one scheduler decision. SQL indexes own
    # freshness and historical lookups; this object keeps only the records a
    # caller already observed during the decision.
    class AdmissionView
      attr_reader :hot_scan

      def initialize(store:, hot_scan:)
        @store = store
        @hot_scan = hot_scan
        @records = hot_scan.records.to_h { |record| [ record.attempt_id, record ] }
      end

      def records
        @records.keys.each do |attempt_id|
          current = @store.fetch(attempt_id)
          current ? @records[attempt_id] = current : @records.delete(attempt_id)
        end
        @records.values.freeze
      end

      def refresh_for_admission = records

      def capacity(now:, records: nil)
        current = records || self.records
        CapacitySnapshot.build(
          store: @store,
          scan: Scan.new(
            records: current.freeze,
            invalid_records: hot_scan.invalid_records
          ),
          now: now
        )
      end

      def failure_cohort_admission(**attributes)
        repository.failure_cohort_admission(**attributes)
      end

      def claim_failure_cohort_probe(**attributes)
        repository.claim_failure_cohort_probe(**attributes)
      end

      def release_failure_cohort_probe(**attributes)
        repository.release_failure_cohort_probe(**attributes)
      end

      def record(record)
        @records[record.attempt_id] = record
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
        find(repository.terminal_attempt_id(request_id: request_id))
      end

      def latest_terminal_attempt(task_generation:, subject:)
        find(
          repository.latest_terminal_attempt_id(
            task_generation: task_generation, subject: subject
          )
        )
      end

      def successful_attempt(task_generation:, subject:)
        find(
          repository.successful_attempt_id(
            task_generation: task_generation, subject: subject
          )
        )
      end

      def unresolved_loss(task_generation:, subject:)
        find(
          repository.unresolved_loss_attempt_id(
            task_generation: task_generation, subject: subject
          )
        )
      end

      def successor(predecessor_attempt_id:)
        find(
          repository.successor_attempt_id(
            predecessor_attempt_id: predecessor_attempt_id
          )
        )
      end

      def record_routing_decision(decision:, task_generation:, subject:, project:,
                                  attempt_id: nil)
        repository.record_routing_decision(
          decision: decision,
          task_generation: task_generation,
          subject: subject,
          project: project,
          attempt_id: attempt_id
        )
      end

      def routing_decision(task_generation:, subject:)
        repository.routing_decision(
          task_generation: task_generation,
          subject: subject
        )
      end

      private

      def repository = @store
    end
  end
end
