require "open3"
require "json"
require "time"

module Hive
  module Daemon
    # Wraps `hive status --json` invocation. Returns a typed array of
    # task rows the daemon's dispatcher consumes. Surfaces parse failures
    # as a structured `{ok: false}` rather than raising, so a transient
    # status hiccup doesn't crash the daemon.
    class StatusConsumer
      Row = Struct.new(:project, :slug, :stage, :marker, :folder, :state_file,
                       :state_file_mtime, :action, :suggested_command, :claude_pid_alive,
                       keyword_init: true)
      Result = Struct.new(:ok, :rows, :error, keyword_init: true)

      def initialize(hive_bin: ENV.fetch("HIVE_BIN", "hive"),
                     extra_env: {})
        @hive_bin = hive_bin
        @extra_env = extra_env
      end

      def fetch
        out, err, status = Open3.capture3(@extra_env, @hive_bin, "status", "--json")
        unless status.success?
          return Result.new(ok: false, rows: [],
                            error: "hive status exited #{status.exitstatus}: #{err.strip}")
        end

        doc = JSON.parse(out)
        validate_envelope!(doc)
        rows = extract_rows(doc)
        Result.new(ok: true, rows: rows, error: nil)
      rescue JSON::ParserError => e
        Result.new(ok: false, rows: [], error: "malformed JSON from hive status: #{e.message}")
      rescue StandardError => e
        Result.new(ok: false, rows: [], error: "#{e.class}: #{e.message}")
      end

      private

      def validate_envelope!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == "hive-status"
          raise ArgumentError, "missing schema=hive-status in envelope"
        end
        unless doc["ok"] == true
          raise ArgumentError, "envelope ok=false: #{doc['error_class']} #{doc['message']}"
        end
        expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
        return if doc["schema_version"] == expected

        raise ArgumentError, "schema_version mismatch: got #{doc['schema_version']}, want #{expected}"
      end

      def extract_rows(doc)
        rows = []
        Array(doc["projects"]).each do |project_doc|
          # Skip projects with errors at the project level (missing path,
          # not initialised) — these aren't dispatchable.
          next if project_doc["error"]

          project = project_doc["name"]
          Array(project_doc["tasks"]).each do |task|
            rows << Row.new(
              project: project,
              slug: task["slug"],
              stage: task["stage"],
              marker: task["marker"],
              folder: task["folder"],
              state_file: task["state_file"],
              state_file_mtime: parse_mtime(task["mtime"], task["state_file"]),
              action: task["action"],
              suggested_command: task["suggested_command"],
              claude_pid_alive: task["claude_pid_alive"]
            )
          end
        end
        rows
      end

      def parse_mtime(iso_string, state_file_path)
        return Time.parse(iso_string) if iso_string && !iso_string.empty?
      rescue ArgumentError
        # Fallthrough to File.mtime
      ensure
        # If the envelope didn't include mtime (unlikely with current
        # schema, but be defensive), stat the state file directly.
        return File.mtime(state_file_path) if state_file_path && File.exist?(state_file_path)
      end
    end
  end
end
