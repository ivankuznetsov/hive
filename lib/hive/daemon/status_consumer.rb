require "time"
require "hive/dependency_admission"
require "hive/commands/status"

module Hive
  module Daemon
    # Maps Hive's in-process task graph into the typed rows consumed by the
    # daemon. Producer failures become `{ok: false}` results so one bad scan
    # does not crash the daemon.
    class StatusConsumer
      # `live_task_lock` is the per-task `.lock`-holder-alive signal
      # `Hive::Commands::Status` derives from a PID + process_start_time
      # match. It is true while a `hive run` invocation is actively inside
      # the task — including pre-stage work like auto-rebase — even before
      # the runner has written its claude_pid to the lock. The daemon
      # healer and dispatcher both need this so they don't race the runner
      # during the pre-claude window (issue #144).
      Row = Struct.new(:project, :slug, :id, :stage, :workflow, :marker, :marker_attrs, :folder, :state_file,
                       :status_payload_mtime, :state_file_mtime,
                       :action, :suggested_command, :claude_pid_alive,
                       :live_task_lock, :task_lock_pid, :task_lock_process_start_time,
                       :task_lock_id, :diagnostic, :depends_on, :blocked_by,
                       :dependency_stage, :blocked, :admission_error,
                       :attempt_id, :task_generation,
                       :condition_task_generation, :commit_generation, :current_attempt,
                       :conditions, :condition_history, :evidence, :condition_overrides, :condition_gate,
                       :condition_migration, :condition_provenance, :shadow_audit,
                       :condition_warning, :pr_url,
                       :plan_review, :projection_repair,
                       keyword_init: true)
      # Aggregated per-project legacy-layout signal lifted out of each
      # project payload's `legacy_stage_dirs` array. The dispatcher uses
      # this to skip dispatching ANY task for a half-migrated project —
      # advancing on top of a renamed stage dir would silently lose work.
      # `legacy_stage_dirs` is the project payload's array verbatim (empty
      # when the project is clean). Issue #95.
      ProjectInfo = Struct.new(
        :name, :legacy_stage_dirs, :hidden_archived_task_count,
        keyword_init: true
      ) do
        def initialize(name:, legacy_stage_dirs: [], hidden_archived_task_count: 0)
          super
        end

        def legacy?
          !Array(legacy_stage_dirs).empty?
        end
      end
      # `warning` carries non-fatal status-projection advisories that the
      # dispatcher logs once per tick. nil on a clean fetch.
      # Full reads also retain the validated source payload so the daemon can
      # publish the graph it already paid to collect; bounded reads leave it
      # nil because they are not an authoritative fleet snapshot.
      Result = Struct.new(
        :ok, :rows, :projects, :error, :warning,
        :hidden_archived_task_count, :status_payload,
        keyword_init: true
      ) do
        def initialize(
          ok:,
          rows: [],
          projects: [],
          error: nil,
          warning: nil,
          hidden_archived_task_count: 0,
          status_payload: nil
        )
          super
        end
      end

      def initialize(producer: nil)
        @producer = producer || method(:produce_in_process)
      end

      def fetch
        fetch_producer
      end

      def fetch_tasks(task_keys)
        keys = Array(task_keys).map do |project, slug|
          [ project.to_s, slug.to_s ]
        end.uniq
        return Result.new(ok: true) if keys.empty?
        fetch_producer(
          task_keys: keys, require_partial: true, expected_task_keys: keys
        )
      end

      private

      def fetch_producer(task_keys: nil, require_partial: false, expected_task_keys: nil)
        warnings = []
        doc = @producer.call(task_keys: task_keys, warnings: warnings)
        consume_document(
          doc, warning: warnings.join(" | "), require_partial: require_partial,
          expected_task_keys: expected_task_keys
        )
      rescue StandardError => e
        failed_result(e, warnings: warnings)
      end

      def produce_in_process(task_keys:, warnings:)
        references = Array(task_keys).map { |project, slug| "#{project}:#{slug}" }
        Hive::Commands::Status.new(
          daemon_tasks: references, warning_sink: warnings
        ).internal_task_graph_payload
      end

      def consume_document(doc, warning: "", require_partial: false, expected_task_keys: nil)
        validate_envelope!(doc)
        if require_partial && doc["partial"] != true
          raise ArgumentError, "bounded status response is missing partial=true"
        end
        validate_bounded_projects!(doc, expected_task_keys) if require_partial
        rows = extract_rows(doc)
        validate_bounded_rows!(rows, expected_task_keys) if require_partial
        projects = extract_projects(doc)
        Result.new(
          ok: true, rows: rows, projects: projects, error: nil,
          warning: warning.empty? ? nil : warning,
          hidden_archived_task_count: projects.sum(&:hidden_archived_task_count),
          status_payload: require_partial ? nil : doc
        )
      end

      def failed_result(error, warnings: [])
        details = [ "#{error.class}: #{error.message}" ]
        details << "projection warnings: #{warnings.join(' | ')}" unless warnings.empty?
        Result.new(
          ok: false, rows: [], projects: [], hidden_archived_task_count: 0,
          error: details.join(" | ")
        )
      end

      def validate_envelope!(doc)
        unless doc.is_a?(Hash) && doc["schema"] == "hive-status"
          raise ArgumentError, "missing schema=hive-status in envelope"
        end
        expected = Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status")
        unless doc["schema_version"] == expected
          raise ArgumentError,
                "hive-status schema version must be #{expected}, got #{doc['schema_version'].inspect}"
        end
        return if doc["ok"] == true

        raise ArgumentError, "envelope ok=false: #{doc['error_class']} #{doc['message']}"
      end

      def validate_bounded_projects!(doc, expected_task_keys)
        expected_projects = Array(expected_task_keys).map(&:first).uniq.sort
        projects = Array(doc["projects"])
        actual_projects = projects.map { |project| project["name"].to_s }.uniq.sort
        unless actual_projects == expected_projects
          raise ArgumentError,
                "bounded status response projects do not match requested projects"
        end

        failed = projects.find { |project| project["error"] }
        return unless failed

        raise ArgumentError,
              "bounded status project #{failed['name']} failed: #{failed['error']}"
      end

      def validate_bounded_rows!(rows, expected_task_keys)
        expected = Array(expected_task_keys).each_with_object({}) do |key, index|
          index[key] = true
        end
        unexpected = rows.find { |row| !expected[[ row.project.to_s, row.slug.to_s ]] }
        return unless unexpected

        raise ArgumentError,
              "bounded status returned unrequested task #{unexpected.project}:#{unexpected.slug}"
      end

      def extract_rows(doc)
        rows = []
        Array(doc["projects"]).each do |project_doc|
          # Skip projects with errors at the project level (missing path,
          # not initialised) — these aren't dispatchable.
          next if project_doc["error"]

          project = project_doc["name"]
          Array(project_doc["tasks"]).each do |task|
            admission_error = extract_admission_error(task)
            rows << Row.new(
              project: project,
              slug: task["slug"],
              id: task["id"],
              stage: task["stage"],
              workflow: task["workflow"],
              marker: task["marker"],
              marker_attrs: task["attrs"].is_a?(Hash) ? task["attrs"] : {},
              projection_repair: task["projection_repair"] == true,
              folder: task["folder"],
              state_file: task["state_file"],
              status_payload_mtime: task["mtime"],
              state_file_mtime: parse_mtime(task["mtime"], task["state_file"]),
              action: admission_error ? "admission_error" : task["action"],
              suggested_command: admission_error ? nil : task["suggested_command"],
              claude_pid_alive: task["claude_pid_alive"],
              live_task_lock: task["live_task_lock"] == true,
              attempt_id: task["attempt_id"],
              task_generation: task["task_generation"],
              task_lock_pid: task["task_lock_pid"],
              task_lock_process_start_time: task["task_lock_process_start_time"],
              task_lock_id: task["task_lock_id"],
              condition_task_generation: task["condition_task_generation"],
              commit_generation: task["commit_generation"],
              current_attempt: task["current_attempt"],
              conditions: Array(task["conditions"]),
              condition_history: Array(task["condition_history"]),
              evidence: Array(task["evidence"]),
              condition_overrides: Array(task["condition_overrides"]),
              condition_gate: task["condition_gate"],
              condition_migration: task["condition_migration"],
              condition_provenance: task["condition_provenance"] || {},
              shadow_audit: task["shadow_audit"] || {},
              condition_warning: task["condition_warning"],
              pr_url: task["pr_url"],
              plan_review: task["plan_review"],
              diagnostic: task["diagnostic"],
              depends_on: task["depends_on"],
              blocked_by: task["blocked_by"],
              dependency_stage: task["dependency_stage"],
              blocked: admission_error ? true : task["blocked"] == true,
              admission_error: admission_error
            )
          end
        end
        rows
      end

      # Admission fields are policy-bearing, so schema drift must hold the
      # row instead of silently treating an absent or malformed object as
      # a clear dependency. A well-formed nil is the only clear value.
      def extract_admission_error(task)
        unless task.key?("admission_error")
          return admission_backstop(task, "missing admission_error field")
        end

        value = task["admission_error"]
        return nil if value.nil?

        keys = %w[reason_code offending_ref safe_correction]
        unless value.is_a?(Hash) && value.keys.sort == keys.sort &&
               Hive::DependencyAdmission::REASON_CODES.include?(value["reason_code"]) &&
               keys.all? { |key| value[key].is_a?(String) && !value[key].empty? }
          return admission_backstop(task, "malformed admission_error field")
        end

        Hive::DependencyAdmission::AdmissionError.new(
          reason_code: value["reason_code"],
          offending_ref: value["offending_ref"],
          safe_correction: value["safe_correction"]
        )
      end

      def admission_backstop(task, problem)
        Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "dependency_validation_failed",
          offending_ref: task["slug"].to_s,
          safe_correction: "Restart or update Hive and inspect status output before dispatching (#{problem})."
        )
      end

      # Surface per-project payload-level signal (legacy_stage_dirs) so
      # the dispatcher can gate dispatch on a project being in a clean
      # layout, without re-walking the graph. Skips error projects (same
      # filter as extract_rows) so the projects list is in 1:1
      # correspondence with dispatchable projects. Issue #95.
      def extract_projects(doc)
        Array(doc["projects"]).reject { |p| p["error"] }.map do |project_doc|
          hidden_count = project_doc.fetch("hidden_archived_task_count", 0)
          unless hidden_count.is_a?(Integer) && hidden_count >= 0
            raise ArgumentError,
                  "project #{project_doc['name'].inspect} has invalid " \
                  "hidden_archived_task_count #{hidden_count.inspect}"
          end

          ProjectInfo.new(
            name: project_doc["name"],
            legacy_stage_dirs: Array(project_doc["legacy_stage_dirs"]),
            hidden_archived_task_count: hidden_count
          )
        end
      end

      def parse_mtime(iso_string, state_file_path)
        # The internal task graph serializes mtimes at whole-second ISO8601
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
