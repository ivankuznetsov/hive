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
      Row = Struct.new(:project, :slug, :stage, :workflow, :marker, :marker_attrs, :folder, :state_file,
                       :state_file_mtime, :action, :suggested_command, :claude_pid_alive,
                       :live_task_lock, :diagnostic, :depends_on, :blocked_by,
                       :dependency_stage, :blocked, :attempt_id, :task_generation,
                       :condition_task_generation, :commit_generation, :current_attempt,
                       :conditions, :condition_history, :evidence, :condition_gate,
                       :condition_migration, :condition_provenance, :shadow_audit,
                       :condition_warning, :retry,
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
      # `warning` carries a non-fatal advisory the dispatcher logs once per
      # tick. Two sources feed it: (1) a forward schema-version skew that was
      # tolerated and parsed best-effort, and (2) any non-empty stderr from an
      # otherwise-successful (exit-0) `hive status --json` fetch. In JSON mode
      # stdout carries the payload and stderr is empty on a healthy run, so
      # non-empty stderr is the status command's own degradation breadcrumbs
      # (fail-open dependency gate, dropped depends_on). (The collapsed-stack
      # warn fires only from the execute/open_pr child processes, never the
      # status command, so it never reaches this channel.)
      # Surfacing it here makes those breadcrumbs observable in daemon.log
      # instead of being silently discarded. nil on a clean fetch.
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
        # Envelope SHAPE validation runs OUTSIDE the best-effort extraction
        # rescue below: a missing schema / ok=false is a real failure whose
        # message must ALWAYS surface, even on a newer-schema doc. Folding
        # it into the skew degrade would relabel a genuine "ok=false:
        # <reason>" as a misleading "restart to pick up the new version".
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

        begin
          rows = extract_rows(doc)
          projects = extract_projects(doc)
        rescue StandardError => e
          # ONLY a failure inside best-effort EXTRACTION degrades. On a
          # newer-schema doc this is the tolerated forward-skew path, but we
          # PRESERVE the underlying exception (class + message) in the
          # surfaced error so a genuine extraction bug stays recoverable —
          # an operator who restarts into the same buggy binary would
          # otherwise keep chasing the friendly "restart" hint. On an
          # exact/equal-version doc there is nothing to tolerate: re-raise to
          # the outer rescue, which records the raw "#{e.class}: ...".
          raise unless skew == :newer

          return Result.new(ok: false, rows: [], projects: [],
                            error: forward_skew_message(doc, underlying: e))
        end
        Result.new(ok: true, rows: rows, projects: projects, error: nil,
                   warning: success_warning(skew, doc, err))
      rescue JSON::ParserError => e
        Result.new(ok: false, rows: [], projects: [],
                   error: "malformed JSON from hive status: #{e.message}")
      rescue StandardError => e
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

      # Compose the success-path advisory from the (optional) tolerated-skew
      # message and any non-empty stderr this fetch emitted, so one warning
      # channel surfaces both. On a healthy JSON fetch stderr is empty and
      # there is no skew → both arms are nil → warning is nil.
      def success_warning(skew, doc, stderr)
        parts = []
        parts << forward_skew_warning(doc) if skew == :newer
        breadcrumbs = stderr.to_s.strip
        parts << "hive status stderr: #{breadcrumbs}" unless breadcrumbs.empty?
        parts.empty? ? nil : parts.join(" | ")
      end

      def forward_skew_warning(doc)
        "#{forward_skew_summary(doc)}; parsing best-effort. " \
          "Restart the hive daemon to pick up the new schema."
      end

      # `underlying` is the exception that aborted best-effort extraction on
      # a newer-schema doc. We append its class + message so the genuine
      # defect stays diagnosable in the daemon log / status_failure event
      # instead of being masked by the friendly restart hint — an operator
      # who restarts into the same buggy binary would otherwise keep
      # chasing the hint.
      def forward_skew_message(doc, underlying:)
        "hive status: #{forward_skew_summary(doc)}; " \
          "restart the hive daemon to pick up the new version " \
          "(underlying error: #{underlying.class}: #{underlying.message})"
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
              workflow: task["workflow"],
              marker: task["marker"],
              marker_attrs: task["attrs"].is_a?(Hash) ? task["attrs"] : {},
              folder: task["folder"],
              state_file: task["state_file"],
              state_file_mtime: parse_mtime(task["mtime"], task["state_file"]),
              action: task["action"],
              suggested_command: task["suggested_command"],
              claude_pid_alive: task["claude_pid_alive"],
              live_task_lock: task["live_task_lock"] == true,
              attempt_id: task["attempt_id"],
              task_generation: task["task_generation"],
              condition_task_generation: task["condition_task_generation"],
              commit_generation: task["commit_generation"],
              current_attempt: task["current_attempt"],
              conditions: Array(task["conditions"]),
              condition_history: Array(task["condition_history"]),
              evidence: Array(task["evidence"]),
              condition_gate: task["condition_gate"],
              condition_migration: task["condition_migration"],
              condition_provenance: task["condition_provenance"] || {},
              shadow_audit: task["shadow_audit"] || {},
              condition_warning: task["condition_warning"],
              retry: task["retry"].is_a?(Hash) ? task["retry"] : nil,
              diagnostic: task["diagnostic"],
              depends_on: task["depends_on"],
              blocked_by: task["blocked_by"],
              dependency_stage: task["dependency_stage"],
              blocked: task["blocked"] == true
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
        # `hive status --json` serializes mtimes at whole-second ISO8601
        # precision for the public payload, but the daemon's edit-resume
        # baseline is captured from File.mtime with subsecond precision.
        # Prefer the local stat when the path is available so an operator
        # answer written in the same second as an agent's WAITING marker
        # still compares newer than the post-child baseline.
        return File.mtime(state_file_path) if state_file_path && File.exist?(state_file_path)

        if iso_string && !iso_string.empty?
          begin
            return Time.parse(iso_string)
          rescue ArgumentError
            nil
          end
        end
        nil
      end
    end
  end
end
