require "json"
require "open3"
require "time"

module Hive
  module Bot
    class StatusWatcher
      Row = Data.define(:project, :project_path, :hive_state_path, :slug, :id, :display_name, :stage, :workflow, :marker,
                        :attrs, :folder, :state_file, :pr_url, :state_file_mtime, :age_seconds,
                        :action, :action_label, :suggested_command, :next_action, :diagnostic,
                        :condition_task_generation, :commit_generation, :current_attempt,
                        :conditions, :condition_history, :evidence, :condition_gate,
                        :condition_migration, :condition_provenance, :shadow_audit,
                        :condition_warning, :scheduling_proof) do
        def initialize(project:, slug:, id: nil, display_name: nil, project_path: nil, hive_state_path: nil,
                       stage: nil, workflow: nil, marker: nil, attrs: {}, folder: nil,
                       state_file: nil, pr_url: nil, state_file_mtime: nil, age_seconds: nil,
                       action: nil, action_label: nil, suggested_command: nil,
                       next_action: nil, diagnostic: nil, condition_task_generation: nil,
                       commit_generation: nil, current_attempt: nil, conditions: [],
                       condition_history: [], evidence: [], condition_gate: nil,
                       condition_migration: nil, condition_provenance: {}, shadow_audit: {},
                       condition_warning: nil, scheduling_proof: nil)
          # Explicit-keyword super (matching Snapshot::Row) rather than the
          # bare positional form, so a future member-order change in the
          # Data.define above can't silently misbind constructor arguments.
          super(
            project: project, project_path: project_path, hive_state_path: hive_state_path,
            slug: slug, id: id, display_name: display_name, stage: stage, workflow: workflow, marker: marker,
            attrs: attrs, folder: folder, state_file: state_file, pr_url: pr_url,
            state_file_mtime: state_file_mtime, age_seconds: age_seconds, action: action,
            action_label: action_label, suggested_command: suggested_command,
            next_action: next_action, diagnostic: diagnostic,
            condition_task_generation: condition_task_generation,
            commit_generation: commit_generation, current_attempt: current_attempt,
            conditions: conditions, condition_history: condition_history, evidence: evidence,
            condition_gate: condition_gate, condition_migration: condition_migration,
            condition_provenance: condition_provenance, shadow_audit: shadow_audit,
            condition_warning: condition_warning, scheduling_proof: scheduling_proof
          )
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

      # `warning` carries a non-fatal advisory (currently: a forward
      # schema-version skew was tolerated and parsed best-effort). The
      # supervisor prepends a one-line banner to the rendered `/status`
      # reply when present. nil on a clean fetch. Mirrors the daemon's
      # StatusConsumer::Result#warning.
      Result = Data.define(:ok, :rows, :legacy_stage_dirs, :error, :envelope, :warning, :scheduler) do
        def initialize(ok:, rows: [], legacy_stage_dirs: [], error: nil, envelope: nil, warning: nil,
                       scheduler: nil)
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
        # Envelope SHAPE validation runs OUTSIDE the best-effort extraction
        # rescue below: a missing schema / ok=false is a real failure whose
        # message must ALWAYS surface, even on a newer-schema doc. Folding
        # it into the skew degrade would relabel a genuine "ok=false:
        # <reason>" as a misleading "restart to pick up the new version".
        validate_envelope!(doc)
        skew = schema_skew(doc)
        # An OLDER payload (a stale `hive` on PATH than this process
        # expects) cannot be trusted to carry the fields we read, so we
        # do not attempt a best-effort parse — surface a clear, actionable
        # message instead of crashing. A NEWER (or equal) payload is parsed
        # best-effort: hive-status envelopes are additive by contract, so
        # an updated binary's output is still readable by an older
        # long-running process.
        return failure(older_skew_message(doc)) if skew == :older

        begin
          rows = extract_rows(doc, now: now)
          legacy_stage_dirs = extract_legacy_stage_dirs(doc)
        rescue StandardError => e
          # ONLY a failure inside best-effort EXTRACTION degrades. On a
          # newer-schema doc this is the tolerated forward-skew path, but we
          # PRESERVE the underlying exception (class + message) in the
          # surfaced error AND log it, so a genuine extraction bug stays
          # recoverable instead of being masked by the friendly restart
          # hint. On an exact/equal-version doc there is nothing to
          # tolerate: re-raise to the outer rescue (raw "#{e.class}: ...").
          raise unless skew == :newer

          return failure(forward_skew_message(doc, underlying: e), underlying: e)
        end

        warn_forward_skew(doc) if skew == :newer
        Result.new(
          ok: true,
          rows: rows,
          legacy_stage_dirs: legacy_stage_dirs,
          error: nil,
          envelope: doc,
          warning: (skew == :newer ? forward_skew_warning(doc) : nil),
          scheduler: doc["scheduler"]
        )
      rescue JSON::ParserError => e
        failure("malformed JSON from hive status: #{e.message}")
      rescue StandardError => e
        failure("#{e.class}: #{e.message}")
      end

      private

      # `underlying`, when present, is the exception that aborted
      # best-effort extraction on a newer-schema doc. We log its class,
      # message, and a few backtrace lines so the genuine defect stays
      # diagnosable in the bot log even though the user-facing `error`
      # leads with the friendly restart hint.
      def failure(message, underlying: nil)
        @logger&.event(:poll_failure, source: "status", message: message)
        if underlying
          @logger&.event(
            :poll_schema_skew, source: "status",
            error_class: underlying.class.name, message: underlying.message,
            backtrace: Array(underlying.backtrace).first(3)
          )
        end
        Result.new(ok: false, rows: [], legacy_stage_dirs: [], error: message)
      end

      # Envelope-shape validation (hard errors) ONLY. A missing/wrong
      # `schema` key or `ok=false` is a malformed/failed envelope and must
      # still raise. Schema VERSION skew is NOT validated here — it is
      # handled tolerantly via `schema_skew` so a binary/process version
      # mismatch never hard-crashes a long-running consumer (bot `/status`).
      def validate_envelope!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == "hive-status"
          raise ArgumentError, "missing schema=hive-status in envelope"
        end
        raise ArgumentError, "envelope ok=false: #{doc['message']}" unless doc["ok"] == true
      end

      # Classify the envelope's schema_version against what THIS process
      # was built for: :match, :newer (payload from an updated binary), or
      # :older (a stale binary on PATH). Never raises.
      def schema_skew(doc)
        got = doc["schema_version"]
        return :match if got == expected_schema_version
        return :newer if got.is_a?(Integer) && got > expected_schema_version

        :older
      end

      # The forward-skew advisory is logged under a DISTINCT event name
      # (not :poll_failure) so it isn't conflated with real fetch failures
      # — the success path tolerated a newer schema, it didn't fail.
      def warn_forward_skew(doc)
        @logger&.event(
          :poll_schema_skew, source: "status",
          message: "#{forward_skew_summary(doc)}; parsing best-effort. " \
                   "Restart the hive bot to pick up the new schema."
        )
      end

      # Non-fatal advisory carried on the success-path Result#warning so the
      # supervisor can surface a banner on `/status`.
      def forward_skew_warning(doc)
        "#{forward_skew_summary(doc)}; parsing best-effort. " \
          "Restart the hive bot to pick up the new schema."
      end

      # `underlying` is the exception that aborted best-effort extraction on
      # a newer-schema doc. We append its class + message so the genuine
      # defect stays diagnosable in the surfaced error instead of being
      # masked by the friendly restart hint.
      def forward_skew_message(doc, underlying:)
        "hive status: #{forward_skew_summary(doc)}; " \
          "restart the hive bot to pick up the new version " \
          "(underlying error: #{underlying.class}: #{underlying.message})"
      end

      def forward_skew_summary(doc)
        "envelope schema v#{doc['schema_version']} is newer than this process (v#{expected_schema_version})"
      end

      def older_skew_message(doc)
        "hive status: envelope schema v#{doc['schema_version']} is older than this process " \
          "(v#{expected_schema_version}); update/reinstall the hive binary on PATH"
      end

      # Computed once and reused. Uses the non-raising `[]` form (not
      # `.fetch`) so it never introduces a fresh KeyError inside a
      # rescue-reachable skew path if the "hive-status" key were ever
      # absent — Finding 4 from the #416 review. Mirrors the daemon's
      # StatusConsumer.
      def expected_schema_version
        @expected_schema_version ||= Hive::Schemas::SCHEMA_VERSIONS["hive-status"]
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
              workflow: task["workflow"],
              marker: task["marker"],
              attrs: task["attrs"] || {},
              folder: task["folder"],
              state_file: task["state_file"],
              pr_url: task["pr_url"],
              state_file_mtime: parse_mtime(task["mtime"], task["state_file"], now: now),
              age_seconds: task["age_seconds"],
              action: task["action"],
              action_label: task["action_label"],
              suggested_command: task["suggested_command"],
              next_action: task["next_action"],
              diagnostic: task["diagnostic"],
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
              scheduling_proof: task["scheduling_proof"]
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
