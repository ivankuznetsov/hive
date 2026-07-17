require "hive/finalization/event"
require "hive/finalization/projection"
require "hive/task_journal"
require "hive/task_projection/store"

module Hive
  module Finalization
    class Reconciler
      PRODUCER = {
        "kind" => "reconciler",
        "name" => "hive-finalization-reconciler-v1"
      }.freeze
      Result = Data.define(:status, :event_id, :projection)

      def initialize(task_folder:, clock: -> { Time.now.utc })
        @task_folder = File.expand_path(task_folder)
        @clock = clock
      end

      def reconcile
        records = Hive::TaskProjection.read_journal(journal_path)
        validate_history!(records)
        finalization = Hive::Finalization::Projection.project(records: records)
        return result(:already_ready, finalization) if finalization.fetch("state") == "archive_ready"
        return result(:not_eligible, finalization) unless %w[merged approved_no_pr].include?(finalization.fetch("state"))

        terminal_event_id = finalization.dig("evidence", "terminal_event_id")
        raise Hive::Finalization::StaleEvidence, "terminal finalization evidence is missing" if terminal_event_id.to_s.empty?

        now = @clock.call.utc.iso8601(6)
        event_id = "#{finalization.fetch('job_id')}:archive-ready:#{terminal_event_id}"
        terminal = records.find { |record| record["event_id"] == terminal_event_id }
        task = terminal&.fetch("task", nil)
        raise Hive::Finalization::StaleEvidence, "terminal event task identity is missing" unless task.is_a?(Hash)

        Hive::TaskJournal::Writer.new(task_folder: @task_folder, clock: @clock).append_once(
          event_id: event_id,
          event_type: "archive_ready",
          occurred_at: now,
          observed_at: now,
          task: task,
          workflow: terminal["workflow"] || "coding",
          stage: terminal["stage"] || "8-finalize", # coding-scoped: finalization journal fallback
          attempt_id: finalization.fetch("finalize_attempt_id"),
          task_generation: finalization.fetch("task_generation"),
          ownership_generation: "finalization-reconciler-v1",
          reason: "current terminal evidence authorizes archive",
          producer: PRODUCER,
          evidence: [ { "kind" => "journal_event", "event_id" => terminal_event_id } ],
          provenance: { "source" => "hive-finalization-reconciler" },
          payload: coordinates(finalization).merge("terminal_event_id" => terminal_event_id)
        )
        projection = Hive::TaskProjection::Store.new(task_folder: @task_folder).rebuild!
        Result.new(status: :archive_ready, event_id: event_id,
                   projection: projection["finalization"])
      end

      private

      def result(status, projection)
        Result.new(
          status: status,
          event_id: projection.dig("evidence", "archive_ready_event_id"),
          projection: projection
        )
      end

      def journal_path
        File.join(@task_folder, Hive::TaskJournal::JOURNAL_BASENAME)
      end

      def validate_history!(records)
        validated = []
        records.each do |record|
          if Hive::Finalization::Event.finalization?(record)
            Hive::Finalization::Event.validate!(record, records: validated)
          end
          validated << record
        end
      end

      def coordinates(finalization)
        Hive::Finalization::Event::COORDINATES.to_h do |key|
          [ key, finalization.fetch(key) ]
        end
      end
    end
  end
end
