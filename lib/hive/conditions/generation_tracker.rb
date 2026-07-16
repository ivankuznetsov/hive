require "digest"
require "json"
require "hive/task_projection"

module Hive
  module Conditions
    class GenerationMismatch < Hive::Error; end

    GenerationDecision = Data.define(
      :task_generation, :input_fingerprint, :advanced, :reason, :invalidation_token
    )
    CommitDecision = Data.define(:commit_generation, :head_sha, :branch, :advanced)

    class GenerationTracker
      INPUT_FILES = %w[plan.md brainstorm.md meta.yml].freeze
      EXPLICIT_ADVANCE_REASONS = %w[
        fenced_repair workflow_invalidation operator_decision accepted_input_changed
      ].freeze

      def initialize(input_files: INPUT_FILES)
        @input_files = input_files
      end

      def input_fingerprint(task:, workflow_policy: {}, operator_decisions: [])
        digest = Digest::SHA256.new
        digest << "hive-condition-input-v1\0"
        @input_files.each do |basename|
          path = File.join(task_folder(task), basename)
          digest << basename << "\0" << file_digest(path) << "\0"
        end
        digest << Hive::TaskProjection.canonical_json(workflow_policy) << "\0"
        digest << Hive::TaskProjection.canonical_json(Array(operator_decisions))
        digest.hexdigest
      end

      def resolve(task:, records: nil, workflow_policy: {}, operator_decisions: [],
                  reason: "accepted_input_changed", invalidation_token: nil)
        records ||= journal_records(task)
        fingerprint = input_fingerprint(
          task: task, workflow_policy: workflow_policy, operator_decisions: operator_decisions
        )
        generation_events = authoritative(records).select { |record| record["event_type"] == "generation_advanced" }
        latest = generation_events.last
        current = authoritative(records).filter_map { |record| record["task_generation"] }.select do |value|
          value.is_a?(Integer)
        end.max || 0
        same_observation = latest &&
                           latest.dig("payload", "input_fingerprint") == fingerprint &&
                           latest.dig("payload", "invalidation_token") == invalidation_token
        generation = same_observation ? latest.fetch("task_generation") : current + 1
        GenerationDecision.new(
          task_generation: generation,
          input_fingerprint: fingerprint,
          advanced: !same_observation,
          reason: reason.to_s,
          invalidation_token: invalidation_token
        )
      end

      def commit(records:, task_generation:, head_sha:, branch:)
        events = authoritative(records).select do |record|
          record["task_generation"] == task_generation &&
            record["event_type"] == "commit_generation_advanced"
        end
        latest = events.last
        current = authoritative(records).filter_map do |record|
          record["commit_generation"] if record["task_generation"] == task_generation
        end.select { |value| value.is_a?(Integer) }.max || 0
        return CommitDecision.new(commit_generation: current, head_sha: nil, branch: branch, advanced: false) if head_sha.nil?
        if latest&.dig("payload", "head_sha") == head_sha
          return CommitDecision.new(
            commit_generation: latest.fetch("commit_generation"),
            head_sha: head_sha, branch: branch, advanced: false
          )
        end

        CommitDecision.new(
          commit_generation: current + 1,
          head_sha: head_sha,
          branch: branch,
          advanced: true
        )
      end

      private

      def journal_records(task)
        Hive::TaskProjection.read_journal(File.join(task_folder(task), "events.jsonl"))
      end

      def task_folder(task)
        return task.folder if task.respond_to?(:folder) && task.folder

        File.dirname(task.state_file)
      end

      def file_digest(path)
        return "missing" unless File.file?(path)

        Digest::SHA256.file(path).hexdigest
      rescue SystemCallError, IOError => e
        Digest::SHA256.hexdigest("unreadable\0#{e.class}\0#{path}")
      end

      def authoritative(records)
        records.select { |record| record["schema"] == Hive::TaskJournal::Envelope::SCHEMA }
      end
    end
  end
end
