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
      # `live_task_lock` is the per-task `.lock`-holder-alive signal
      # `Hive::Commands::Status` derives from a PID + process_start_time
      # match. It is true while a `hive run` invocation is actively inside
      # the task — including pre-stage work like auto-rebase — even before
      # the runner has written its claude_pid to the lock. The daemon
      # healer and dispatcher both need this so they don't race the runner
      # during the pre-claude window (issue #144).
      Row = Struct.new(:project, :slug, :stage, :marker, :marker_attrs, :folder, :state_file,
                       :state_file_mtime, :action, :suggested_command, :claude_pid_alive,
                       :live_task_lock, :diagnostic,
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
      # `warning` carries a non-fatal advisory (currently: a forward
      # schema-version skew was tolerated and parsed best-effort). The
      # dispatcher logs it once per tick. nil on a clean fetch.
      Result = Struct.new(:ok, :rows, :projects, :error, :warning, keyword_init: true)

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
        skew = schema_skew(doc)
        # An OLDER payload (a stale `hive` on PATH than this daemon
        # expects) can't be trusted to carry the fields the dispatcher
        # reads, so surface a clear, actionable failure instead of
        # advancing on stale data. A NEWER (or equal) payload is parsed
        # best-effort: hive-status envelopes are additive by contract, so
        # an updated binary's output stays readable by an older
        # long-running daemon process. The dispatcher logs `warning`.
        return Result.new(ok: false, rows: [], projects: [], error: older_skew_message(doc)) if skew == :older

        rows = extract_rows(doc)
        projects = extract_projects(doc)
        Result.new(ok: true, rows: rows, projects: projects, error: nil,
                   warning: (skew == :newer ? forward_skew_warning(doc) : nil))
      rescue JSON::ParserError => e
        Result.new(ok: false, rows: [], projects: [],
                   error: "malformed JSON from hive status: #{e.message}")
      rescue StandardError => e
        # A newer payload that genuinely failed best-effort extraction
        # degrades to a clear, actionable restart message rather than an
        # opaque "#{e.class}: ..." line that an operator can't act on.
        if defined?(doc) && doc.is_a?(Hash) && schema_skew(doc) == :newer
          return Result.new(ok: false, rows: [], projects: [], error: forward_skew_message(doc))
        end

        Result.new(ok: false, rows: [], projects: [], error: "#{e.class}: #{e.message}")
      end

      private

      # Envelope-shape validation (hard errors) ONLY. A missing/wrong
      # `schema` key or `ok=false` is a malformed/failed envelope and must
      # still raise. Schema VERSION skew is NOT validated here — it is
      # handled tolerantly via `schema_skew` so a binary/process version
      # mismatch never hard-crashes the daemon tick.
      def validate_envelope!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == "hive-status"
          raise ArgumentError, "missing schema=hive-status in envelope"
        end
        return if doc["ok"] == true

        raise ArgumentError, "envelope ok=false: #{doc['error_class']} #{doc['message']}"
      end

      # Classify the envelope's schema_version against what THIS daemon was
      # built for: :match, :newer (payload from an updated binary), or
      # :older (a stale binary on PATH). Never raises.
      def schema_skew(doc)
        expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
        got = doc["schema_version"]
        return :match if got == expected
        return :newer if got.is_a?(Integer) && got > expected

        :older
      end

      def forward_skew_warning(doc)
        "#{forward_skew_summary(doc)}; parsing best-effort. " \
          "Restart the hive daemon to pick up the new schema."
      end

      def forward_skew_message(doc)
        "hive status: #{forward_skew_summary(doc)}; " \
          "restart the hive daemon to pick up the new version"
      end

      def forward_skew_summary(doc)
        expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
        "envelope schema v#{doc['schema_version']} is newer than this process (v#{expected})"
      end

      def older_skew_message(doc)
        expected = Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
        "hive status: envelope schema v#{doc['schema_version']} is older than this process " \
          "(v#{expected}); update/reinstall the hive binary on PATH"
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
              marker_attrs: task["attrs"].is_a?(Hash) ? task["attrs"] : {},
              folder: task["folder"],
              state_file: task["state_file"],
              state_file_mtime: parse_mtime(task["mtime"], task["state_file"]),
              action: task["action"],
              suggested_command: task["suggested_command"],
              claude_pid_alive: task["claude_pid_alive"],
              live_task_lock: task["live_task_lock"] == true,
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
