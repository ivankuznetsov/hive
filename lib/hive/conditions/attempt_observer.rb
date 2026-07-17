require "hive/config"
require "hive/markers"
require "hive/task"
require "hive/task_journal"
require "hive/task_projection/store"
require "set"

module Hive
  module Conditions
    # Projects durable terminal/lost attempt state back into the task journal.
    # The execute worker observes a live lease before it exits; this daemon-side
    # observer closes that lifecycle so a later failed/lost receipt cannot leave
    # an earlier AgentHealthy=satisfied fact current forever.
    class AttemptObserver
      EXECUTE_STAGE = "4-execute" # coding-scoped: condition rollout currently governs coding execute

      def initialize(store:, logger: nil, task_locator: nil)
        @store = store
        @logger = logger
        @task_locator = task_locator || method(:locate_task)
        @delivered = Set.new
      end

      def call(status, now: Time.now.utc)
        attempt = status.attempt
        return false unless attempt["intended_stage"] == EXECUTE_STAGE
        return false unless %w[terminal lost].include?(attempt.state)
        key = delivery_key(attempt)
        return false if @delivered.include?(key)

        task = @task_locator.call(attempt)
        return false unless task
        unless task.workflow.id.to_s == "coding"
          @delivered.add(key)
          return false
        end

        writer = Hive::TaskJournal::Writer.new(
          task_folder: task.folder, attempt_store: @store, clock: -> { now }
        )
        records = Hive::TaskProjection.read_journal(
          writer.path, attempt_store: @store
        )
        if observed?(records, attempt)
          @delivered.add(key)
          return false
        end

        writer.append(observation(task, attempt, status, records))
        marker = Hive::Markers.current(task.state_file)
        Hive::TaskProjection::Store.new(
          task_folder: task.folder, attempt_store: @store
        ).rebuild!(marker: marker)
        @delivered.add(key)
        true
      rescue Hive::Error, SystemCallError, IOError => e
        report_error(status&.attempt, e)
        false
      end

      private

      def delivery_key(attempt)
        [ attempt.attempt_id, attempt.state, attempt.outcome ].freeze
      end

      def observed?(records, attempt)
        records.any? do |record|
          record["event_type"] == "condition_observed" &&
            record["attempt_id"] == attempt.attempt_id &&
            record.dig("payload", "condition") == "AgentHealthy" &&
            record.fetch("evidence", []).any? do |entry|
              entry["type"] == "attempt_lease" &&
                entry["state"] == attempt.state &&
                entry["outcome"] == attempt.outcome
            end
        end
      end

      def observation(task, attempt, status, records)
        state, reason = health(attempt)
        {
          event_type: "condition_observed",
          task: {
            "id" => task.respond_to?(:id) ? task.id&.to_s : nil,
            "slug" => task.slug.to_s
          },
          workflow: task.workflow.id.to_s,
          stage: EXECUTE_STAGE,
          attempt_id: attempt.attempt_id,
          task_generation: attempt.task_input_epoch,
          ownership_generation: attempt.ownership_generation,
          commit_generation: commit_generation(records, attempt.task_input_epoch),
          reason: reason,
          evidence: [
            {
              "type" => "attempt_lease",
              "attempt_id" => attempt.attempt_id,
              "lease_version" => attempt.lease_version,
              "state" => attempt.state,
              "outcome" => attempt.outcome
            }
          ],
          provenance: {
            "source" => "attempt_reconciler",
            "classification" => status.classification.to_s,
            "owner_status" => status.owner_status.to_s,
            "attempt_accepted_at" => attempt["accepted_at"],
            "predecessor_attempt_id" => attempt["predecessor_attempt_id"]
          },
          payload: {
            "condition" => "AgentHealthy",
            "state" => state,
            "informational_after_terminal" => attempt.state == "terminal" && state == "satisfied"
          }
        }
      end

      def health(attempt)
        return [ "unsatisfied", "attempt_lost" ] if attempt.state == "lost"
        return [ "satisfied", "attempt_terminal_succeeded" ] if attempt.outcome == "succeeded"

        [ "unsatisfied", "attempt_terminal_#{attempt.outcome || 'unknown'}" ]
      end

      def commit_generation(records, task_generation)
        records.filter_map do |record|
          record["commit_generation"] if record["task_generation"] == task_generation
        end.select { |value| value.is_a?(Integer) }.max || 0
      end

      def locate_task(attempt)
        project = Hive::Config.find_project(attempt["project"])
        return nil unless project

        pattern = File.join(
          project.fetch("hive_state_path"), "stages", "*", attempt["task_slug"]
        )
        Dir.glob(pattern).filter_map do |folder|
          task = Hive::Task.new(folder)
          next if attempt["task_id"] && task.id.to_s != attempt["task_id"].to_s

          task
        rescue Hive::Error, SystemCallError
          nil
        end.first
      end

      def report_error(attempt, error)
        message = "condition attempt observation failed for " \
                  "#{attempt&.attempt_id || '(unknown)'}: #{error.class}: #{error.message}"
        if @logger
          @logger.event(:fatal, message: message, keeping_previous: true)
        else
          warn "hive: #{message}"
        end
      end
    end
  end
end
