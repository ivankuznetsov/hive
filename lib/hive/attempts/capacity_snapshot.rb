require "date"
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
      def self.build(store:, now: Time.now)
        scan = store.scan
        live = scan.records.select(&:live?)
        per_project = Hash.new(0)
        per_task = Hash.new(0)
        live.each do |record|
          per_project[record["project"]] += 1
          per_task[[ record["project"], record["task_slug"] ]] += 1
        end

        daily = Hash.new(0)
        scan.records.each do |record|
          receipt = record.receipt
          next if receipt && receipt["exit_status"] == Hive::ExitCodes::TEMPFAIL

          date = Time.iso8601(record["accepted_at"]).to_date
          daily[[ record["project"], date ]] += 1
        rescue ArgumentError
          # Record validation already checked the timestamp. Preserve the
          # fail-closed global reservation if a future schema changes it.
          next
        end

        invalid_count = scan.invalid_records.size
        new(
          global_count: live.size + invalid_count,
          per_project: per_project.to_h.freeze,
          per_task: per_task.to_h.freeze,
          daily_counts: daily.to_h.freeze,
          reserved_attempt_ids: live.map(&:attempt_id).freeze,
          invalid_count: invalid_count
        )
      end

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
  end
end
