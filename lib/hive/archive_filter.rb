require "hive/completed_at_backfiller"
require "hive/completion_time"
require "hive/workflows"

module Hive
  # Shared projection for ordinary and dedicated archive surfaces. Archive
  # membership comes from TaskAction; retention only decides whether an
  # already-archived row remains in an ordinary view.
  module ArchiveFilter
    SECONDS_PER_DAY = 24 * 60 * 60

    Projection = Data.define(
      :ordinary_rows, :archive_rows, :hidden_rows, :next_retention_boundary
    ) do
      def hidden_count = hidden_rows.length
    end

    module_function

    def project(rows, now: Time.now.utc, backfiller: Hive::CompletedAtBackfiller.new,
                apply_retention: true)
      rows = Array(rows)
      archive_rows = rows.select { |row| archive_row?(row) }
      unless apply_retention
        return Projection.new(
          ordinary_rows: rows,
          archive_rows: archive_rows,
          hidden_rows: [],
          next_retention_boundary: nil
        )
      end

      archived_rows = archive_rows.select { |row| archive_member?(row) }
      clocks = completion_clocks(archived_rows, backfiller: backfiller)
      hidden_rows = archived_rows.select do |row|
        hide?(
          action: "archived",
          retention: row.dig(:task)&.workflow&.archive_visibility_retention_days,
          completed_at: clocks[row.dig(:task)&.folder],
          now: now
        )
      end
      hidden_ids = hidden_rows.to_h { |row| [ row.object_id, true ] }

      Projection.new(
        ordinary_rows: rows.reject { |row| hidden_ids.key?(row.object_id) },
        archive_rows: archive_rows,
        hidden_rows: hidden_rows,
        next_retention_boundary: next_retention_boundary(
          archived_rows, clocks: clocks, hidden_ids: hidden_ids, now: now
        )
      )
    end

    def archive_row?(row)
      archive_member?(row) || invalid_terminal_row?(row)
    end

    def archive_member?(row)
      row[:archive_member] == true || archived_action?(row)
    end

    def archived_action?(row)
      row[:action_key].to_s == "archived"
    end

    # Strict boundary: exactly N full 24-hour periods remains visible.
    # Invalid/missing clocks and future timestamps fail open.
    def hide?(action:, retention:, completed_at:, now: Time.now.utc)
      return false unless action.to_s == "archived"
      return false if retention == :never
      return false unless retention.is_a?(Integer) && retention.positive?

      completed_at = Hive::CompletionTime.parse(completed_at)
      return false unless completed_at

      (now.utc - completed_at) > (retention * SECONDS_PER_DAY)
    end

    def completion_clocks(rows, backfiller:)
      tasks = rows.filter_map { |row| row[:task] }.uniq { |task| task.folder }
      stored = tasks.to_h do |task|
        [ task.folder, Hive::CompletionTime.parse(task.completed_at, warn_context: task.folder) ]
      end
      missing = tasks.select { |task| stored[task.folder].nil? }
      return stored if missing.empty?

      stored.merge(backfiller.call(missing))
    end

    def next_retention_boundary(rows, clocks:, hidden_ids:, now:)
      rows.filter_map do |row|
        next if hidden_ids.key?(row.object_id)

        task = row[:task]
        retention = task&.workflow&.archive_visibility_retention_days
        completed_at = Hive::CompletionTime.parse(clocks[task&.folder])
        next unless retention.is_a?(Integer) && retention.positive? && completed_at

        boundary = completed_at + (retention * SECONDS_PER_DAY)
        boundary if now.utc <= boundary
      end.min
    end

    # A malformed/unknown workflow cannot be action-classified. If its folder
    # sits in a terminal directory known to the current generation, include the
    # synthetic Error row in the dedicated archive so the defect is observable;
    # it is never eligible for retention hiding or the hidden count.
    def invalid_terminal_row?(row)
      row[:invalid] == true &&
        (row[:archive_member] == true || Hive::Workflows.all_terminal_stage_dirs.include?(row[:stage]))
    end
  end
end
