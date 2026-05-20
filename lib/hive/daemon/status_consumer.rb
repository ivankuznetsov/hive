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
                       :diagnostic,
                       keyword_init: true)
      # Aggregated per-project legacy-layout signal lifted out of each
      # project payload's `legacy_stage_dirs` array. The dispatcher uses
      # this to skip dispatching ANY task for a half-migrated project —
      # advancing on top of a renamed stage dir would silently lose work.
      # `legacy_stage_dirs` is the project payload's array verbatim (empty
      # when the project is clean). Issue #95.
      ProjectInfo = Struct.new(:name, :legacy_stage_dirs, keyword_init: true) do
        def legacy?
          !Array(legacy_stage_dirs).empty?
        end
      end
      Result = Struct.new(:ok, :rows, :projects, :error, keyword_init: true)

      def initialize(hive_bin: ENV.fetch("HIVE_BIN", "hive"),
                     extra_env: {})
        @hive_bin = hive_bin
        @extra_env = extra_env
      end

      def fetch
        out, err, status = Open3.capture3(@extra_env, @hive_bin, "status", "--json")
        unless status.success?
          return Result.new(ok: false, rows: [], projects: [],
                            error: "hive status exited #{status.exitstatus}: #{err.strip}")
        end

        doc = JSON.parse(out)
        validate_envelope!(doc)
        rows = extract_rows(doc)
        projects = extract_projects(doc)
        Result.new(ok: true, rows: rows, projects: projects, error: nil)
      rescue JSON::ParserError => e
        Result.new(ok: false, rows: [], projects: [],
                   error: "malformed JSON from hive status: #{e.message}")
      rescue StandardError => e
        Result.new(ok: false, rows: [], projects: [], error: "#{e.class}: #{e.message}")
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
              claude_pid_alive: task["claude_pid_alive"],
              diagnostic: task["diagnostic"]
            )
          end
        end
        rows
      end

      # Surface per-project payload-level signal (legacy_stage_dirs) so
      # the dispatcher can gate dispatch on a project being in a clean
      # layout, without re-walking the JSON. Skips error projects (same
      # filter as extract_rows) so the projects list is in 1:1
      # correspondence with dispatchable projects. Issue #95.
      def extract_projects(doc)
        Array(doc["projects"]).reject { |p| p["error"] }.map do |project_doc|
          ProjectInfo.new(
            name: project_doc["name"],
            legacy_stage_dirs: Array(project_doc["legacy_stage_dirs"])
          )
        end
      end

      def parse_mtime(iso_string, state_file_path)
        if iso_string && !iso_string.empty?
          begin
            return Time.parse(iso_string)
          rescue ArgumentError
            # Fall through to File.mtime
          end
        end
        # If the envelope didn't include mtime, or it didn't parse,
        # stat the state file directly. nil if the file is gone.
        File.mtime(state_file_path) if state_file_path && File.exist?(state_file_path)
      end
    end
  end
end
