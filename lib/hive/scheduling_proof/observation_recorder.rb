require "digest"
require "json"
require "hive/task_journal"
require "hive/task_projection/store"

module Hive
  module SchedulingProof
    class ObservationRecorder
      SIGNATURE_KEYS = %w[
        project task_id task_slug workflow stage task_generation attempt_id reason
        provider dependency babysitter retry error action
      ].freeze

      def initialize(attempt_store: nil, writer_factory: nil)
        @attempt_store = attempt_store
        @writer_factory = writer_factory
      end

      def record(observation)
        value = stringify(observation)
        folder = value.fetch("task_folder")
        signature = semantic_signature(value)
        projection_store = Hive::TaskProjection::Store.new(task_folder: folder)
        current = projection_store.read.to_h.dig("scheduling", "current")
        return false if current&.fetch("semantic_signature", nil) == signature

        writer_for(folder).append(
          event_type: "scheduling_observed",
          task: { "id" => value["task_id"], "slug" => value.fetch("task_slug") },
          workflow: value["workflow"],
          stage: value.fetch("stage"),
          attempt_id: value["attempt_id"],
          task_generation: value.fetch("task_generation"),
          ownership_generation: nil,
          commit_generation: nil,
          reason: value.fetch("reason"),
          observed_at: value.fetch("observed_at"),
          evidence: [],
          provenance: { "source" => "scheduler_tick" },
          payload: {
            "semantic_signature" => signature,
            "observation" => value.reject { |key, _| key == "task_folder" }
          }
        )
        projection_store.rebuild!
        true
      end

      def semantic_signature(observation)
        value = stringify(observation)
        selected = SIGNATURE_KEYS.to_h { |key| [ key, value[key] ] }
        ::Digest::SHA256.hexdigest(JSON.generate(canonical(selected)))
      end

      private

      def writer_for(folder)
        return @writer_factory.call(folder) if @writer_factory

        Hive::TaskJournal::Writer.new(task_folder: folder, attempt_store: @attempt_store)
      end

      def stringify(value)
        value.to_h.to_h do |key, child|
          normalized = if child.is_a?(Hash)
            stringify(child)
          elsif child.is_a?(Array)
            child.map { |entry| entry.is_a?(Hash) ? stringify(entry) : entry }
          else
            child
          end
          [ key.to_s, normalized ]
        end
      end

      def canonical(value)
        case value
        when Hash then value.keys.sort.to_h { |key| [ key, canonical(value[key]) ] }
        when Array then value.map { |child| canonical(child) }
        else value
        end
      end
    end
  end
end
