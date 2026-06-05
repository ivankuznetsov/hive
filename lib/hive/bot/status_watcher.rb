require "json"
require "open3"
require "time"

module Hive
  module Bot
    class StatusWatcher
      Row = Data.define(:project, :project_path, :hive_state_path, :slug, :id, :display_name, :stage, :marker,
                        :attrs, :folder, :state_file, :state_file_mtime, :age_seconds,
                        :action, :action_label, :suggested_command, :next_action, :diagnostic) do
        def initialize(project:, slug:, id: nil, display_name: nil, project_path: nil, hive_state_path: nil,
                       stage: nil, marker: nil, attrs: {}, folder: nil,
                       state_file: nil, state_file_mtime: nil, age_seconds: nil,
                       action: nil, action_label: nil, suggested_command: nil,
                       next_action: nil, diagnostic: nil)
          super
        end
      end

      LegacyStageDirs = Data.define(:project, :project_path, :hive_state_path,
                                    :legacy_stage_dirs, :legacy_migrate_command) do
        def initialize(project:, project_path: nil, hive_state_path: nil,
                       legacy_stage_dirs: [], legacy_migrate_command: nil)
          super(
            project: project,
            project_path: project_path,
            hive_state_path: hive_state_path,
            legacy_stage_dirs: normalize_stage_dirs(legacy_stage_dirs),
            legacy_migrate_command: legacy_migrate_command
          )
        end

        def slug
          "__legacy_stage_dirs__"
        end

        def stage
          "legacy_stage_dirs"
        end

        def marker
          "legacy_stage_dirs"
        end

        def action
          "legacy_stage_dirs"
        end

        def attrs
          {
            "stage_dirs" => stage_dir_names.join(","),
            "task_count" => total_task_count.to_s
          }
        end

        def stage_dir_names
          legacy_stage_dirs.map { |entry| entry.fetch("stage_dir") }
        end

        def total_task_count
          legacy_stage_dirs.sum { |entry| entry.fetch("task_count").to_i }
        end

        private

        def normalize_stage_dirs(entries)
          Array(entries).filter_map do |entry|
            raw = entry.is_a?(Hash) ? entry : {}
            stage_dir = raw["stage_dir"].to_s
            task_count = raw["task_count"].to_i
            next if stage_dir.empty? || task_count <= 0

            { "stage_dir" => stage_dir, "task_count" => task_count }
          end.freeze
        end
      end

      Result = Data.define(:ok, :rows, :legacy_stage_dirs, :error, :envelope) do
        def initialize(ok:, rows: [], legacy_stage_dirs: [], error: nil, envelope: nil)
          super
        end
      end

      def initialize(hive_bin: ENV.fetch("HIVE_BIN", "hive"), extra_env: {}, logger: nil)
        @hive_bin = hive_bin
        @extra_env = extra_env
        @logger = logger
      end

      def tick(now: Time.now)
        fetch(now: now)
      end

      def fetch(now: Time.now)
        out, err, status = Open3.capture3(@extra_env, @hive_bin, "status", "--json")
        unless status.success?
          message = "hive status exited #{status.exitstatus}: #{err.strip}"
          @logger&.event(:poll_failure, source: "status", message: message)
          return Result.new(ok: false, rows: [], error: message)
        end

        doc = JSON.parse(out)
        validate_envelope!(doc)
        Result.new(
          ok: true,
          rows: extract_rows(doc, now: now),
          legacy_stage_dirs: extract_legacy_stage_dirs(doc),
          error: nil,
          envelope: doc
        )
      rescue JSON::ParserError => e
        failure("malformed JSON from hive status: #{e.message}")
      rescue StandardError => e
        failure("#{e.class}: #{e.message}")
      end

      private

      def failure(message)
        @logger&.event(:poll_failure, source: "status", message: message)
        Result.new(ok: false, rows: [], legacy_stage_dirs: [], error: message)
      end

      def validate_envelope!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == "hive-status"
          raise ArgumentError, "missing schema=hive-status in envelope"
        end
        raise ArgumentError, "envelope ok=false: #{doc['message']}" unless doc["ok"] == true

        expected = Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status")
        return if doc["schema_version"] == expected

        raise ArgumentError, "schema_version mismatch: got #{doc['schema_version']}, want #{expected}"
      end

      def extract_legacy_stage_dirs(doc)
        Array(doc["projects"]).filter_map do |project_doc|
          next if project_doc["error"]

          entry = LegacyStageDirs.new(
            project: project_doc["name"],
            project_path: project_doc["path"],
            hive_state_path: project_doc["hive_state_path"],
            legacy_stage_dirs: project_doc["legacy_stage_dirs"],
            legacy_migrate_command: project_doc["legacy_migrate_command"]
          )
          next if entry.legacy_stage_dirs.empty?

          entry
        end
      end

      def extract_rows(doc, now:)
        rows = []
        Array(doc["projects"]).each do |project_doc|
          next if project_doc["error"]

          Array(project_doc["tasks"]).each do |task|
            rows << Row.new(
              project: project_doc["name"],
              project_path: project_doc["path"],
              hive_state_path: project_doc["hive_state_path"],
              slug: task["slug"],
              id: task["id"],
              display_name: task["display_name"],
              stage: task["stage"],
              marker: task["marker"],
              attrs: task["attrs"] || {},
              folder: task["folder"],
              state_file: task["state_file"],
              state_file_mtime: parse_mtime(task["mtime"], task["state_file"], now: now),
              age_seconds: task["age_seconds"],
              action: task["action"],
              action_label: task["action_label"],
              suggested_command: task["suggested_command"],
              next_action: task["next_action"],
              diagnostic: task["diagnostic"]
            )
          end
        end
        rows
      end

      def parse_mtime(iso_string, state_file_path, now:)
        if iso_string && !iso_string.empty?
          begin
            return Time.parse(iso_string)
          rescue ArgumentError
            nil
          end
        end
        return File.mtime(state_file_path) if state_file_path && File.exist?(state_file_path)

        now
      end
    end
  end
end
