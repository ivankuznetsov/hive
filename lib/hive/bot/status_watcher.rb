require "json"
require "open3"
require "time"

module Hive
  module Bot
    class StatusWatcher
      Row = Data.define(:project, :project_path, :hive_state_path, :slug, :stage, :marker,
                        :attrs, :folder, :state_file, :state_file_mtime, :age_seconds,
                        :action, :action_label, :suggested_command, :next_action, :diagnostic) do
        def initialize(project:, slug:, project_path: nil, hive_state_path: nil,
                       stage: nil, marker: nil, attrs: {}, folder: nil,
                       state_file: nil, state_file_mtime: nil, age_seconds: nil,
                       action: nil, action_label: nil, suggested_command: nil,
                       next_action: nil, diagnostic: nil)
          super
        end
      end
      Result = Data.define(:ok, :rows, :error) do
        def initialize(ok:, rows: [], error: nil)
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
        Result.new(ok: true, rows: extract_rows(doc, now: now), error: nil)
      rescue JSON::ParserError => e
        failure("malformed JSON from hive status: #{e.message}")
      rescue StandardError => e
        failure("#{e.class}: #{e.message}")
      end

      private

      def failure(message)
        @logger&.event(:poll_failure, source: "status", message: message)
        Result.new(ok: false, rows: [], error: message)
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
