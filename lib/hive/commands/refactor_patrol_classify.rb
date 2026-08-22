require "json"

require "hive/atomic_file"
require "hive/config"
require "hive/refactor_patrol/merge_classifier"
require "hive/refactor_patrol/merge_classifier_runner"
require "hive/refactor_patrol/state_store"

module Hive
  module Commands
    # Internal supervised child for one durable post-merge semantic gate.
    # The classification store, not this result envelope, is authoritative.
    class RefactorPatrolClassify
      def initialize(project, occurrence_id:, reservation_id:, result_file:, classifier_factory: nil,
                     config_loader: ->(path) { Hive::Config.load(path) })
        @project = project.to_s
        @occurrence_id = occurrence_id.to_s
        @reservation_id = reservation_id.to_s
        @result_file = result_file.to_s
        @classifier_factory = classifier_factory
        @config_loader = config_loader
      end

      def call
        entry = Hive::Config.find_project(@project)
        raise Hive::ConfigError, "unknown project #{@project.inspect}" unless entry

        root = entry.fetch("path")
        cfg = @config_loader.call(root)
        result_path = validate_result_path!(entry)
        classifier = classifier_for(entry, root, cfg)
        record = classifier.run_occurrence(
          @occurrence_id, reservation_id: @reservation_id
        )
        payload = envelope(record)
        Hive::AtomicFile.write(result_path, "#{JSON.generate(payload)}\n", mode: 0o600)
        puts JSON.generate(payload)
        payload
      rescue StandardError => error
        payload = {
          "schema" => "hive-refactor-patrol-merge-classifier-result",
          "schema_version" => 1, "ok" => false,
          "occurrence_id" => @occurrence_id,
          "error" => "#{error.class}: #{error.message}"[0, 2_000]
        }
        begin
          Hive::AtomicFile.write(@validated_result_path, "#{JSON.generate(payload)}\n", mode: 0o600) if
            @validated_result_path
        rescue StandardError
          nil
        end
        puts JSON.generate(payload)
        raise
      end

      private

      def classifier_for(entry, root, cfg)
        return @classifier_factory.call(entry, cfg) if @classifier_factory

        state_root = entry["hive_state_path"] || File.join(root, ".hive-state")
        state = Hive::RefactorPatrol::StateStore.new(
          root, hive_state_path: state_root
        )
        Hive::RefactorPatrol::MergeClassifier.new(
          root: File.join(state_root, "refactor_patrol", "v2", "merge-classifications"),
          decision_provider: Hive::RefactorPatrol::MergeClassifierRunner.new(
            project_root: root, cfg: cfg, state: state
          )
        )
      end

      def validate_result_path!(entry)
        unless @occurrence_id.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::ConfigError, "merge classification occurrence id is invalid"
        end
        unless @reservation_id.match?(/\A[0-9a-f]{64}\z/)
          raise Hive::ConfigError, "merge classification reservation id is invalid"
        end
        state_root = entry["hive_state_path"] || File.join(entry.fetch("path"), ".hive-state")
        root = File.expand_path(File.join(state_root, "refactor_patrol", "v2", "results"))
        path = File.expand_path(@result_file)
        basename = File.basename(path)
        unless File.dirname(path) == root &&
               basename.start_with?("classification-#{@occurrence_id}-") && basename.end_with?(".json")
          raise Hive::ConfigError, "merge classification result path is outside its fenced root"
        end
        @validated_result_path = path
      end

      def envelope(record)
        {
          "schema" => "hive-refactor-patrol-merge-classifier-result",
          "schema_version" => 1, "ok" => true,
          "occurrence_id" => record.fetch("occurrence_id"),
          "status" => record.fetch("status")
        }
      end
    end
  end
end
