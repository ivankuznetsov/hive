require "json"
require "hive/config"
require "hive/refactor_patrol/job_store"

module Hive
  module Commands
    # Operator-only, offline reverse schema transition. The snapshot id is a
    # required positional identity, not an implicit "latest" selector.
    class RefactorPatrolSchemaRestore
      SCHEMA = "hive-refactor-patrol-schema-restore".freeze
      SCHEMA_VERSION = 1

      def initialize(project, snapshot_id, json: false,
                     project_resolver: ->(name) {
                       Hive::Config.find_project(name)
                     },
                     restorer: nil)
        @project = project.to_s
        @snapshot_id = snapshot_id.to_s
        @json = json == true
        @project_resolver = project_resolver
        @restorer = restorer || lambda do |entry|
          Hive::RefactorPatrol::JobStore.restore_schema_v2_snapshot!(
            entry.fetch("real_path"),
            snapshot_id: @snapshot_id,
            hive_state_path: entry.fetch("hive_state_path"),
            project: entry
          )
        end
      end

      def call
        entry = registered_project!
        result = @restorer.call(entry)
        payload = {
          "schema" => SCHEMA,
          "schema_version" => SCHEMA_VERSION,
          "ok" => true,
          "project" => entry.fetch("name"),
          "project_root" => entry.fetch("real_path"),
          "snapshot_id" => result.snapshot_id,
          "restored_jobs" => result.restored_jobs,
          "quarantine_path" => result.quarantine_path
        }
        puts(
          @json ? JSON.generate(payload) :
            "hive refactor-patrol-schema-restore: " \
            "#{payload.fetch('project')} restored_jobs=" \
            "#{payload.fetch('restored_jobs')} snapshot=" \
            "#{payload.fetch('snapshot_id')} quarantine=" \
            "#{payload.fetch('quarantine_path')}"
        )
        result
      end

      private

      def registered_project!
        entry = @project_resolver.call(@project)
        unless entry.is_a?(Hash)
          raise Hive::ConfigError,
                "hive refactor-patrol-schema-restore: unknown project " \
                "#{@project.inspect}"
        end
        path = File.expand_path(entry.fetch("path"))
        real_path = File.realpath(path)
        registered_real_path = File.expand_path(entry.fetch("real_path"))
        unless real_path == registered_real_path
          raise Hive::ConfigError,
                "registered project path no longer matches its canonical path"
        end
        state = File.expand_path(
          entry.fetch("hive_state_path"), real_path
        )
        entry.merge(
          "path" => path,
          "real_path" => real_path,
          "hive_state_path" => state
        )
      rescue KeyError, TypeError, SystemCallError => error
        raise Hive::ConfigError,
              "registered project identity is unavailable " \
              "(#{error.class}: #{error.message})"
      end
    end
  end
end
