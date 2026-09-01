require "json"
require "digest"
require "time"
require "hive/agent_limit"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/stages"
require "hive/workflows"
require "hive/workflows/project"
require "hive/archive_filter"
require "hive/dependencies"
require "hive/dependency_admission"
require "hive/dependency_snapshot"
require "hive/diagnostic_evidence"
require "hive/diagnostic_helpers"
require "hive/secret_patterns"
require "hive/task_action"
require "hive/attempts/repository"
require "hive/patrol_fix/attempt_diagnostic"
require "hive/task_projection/reader"
require "hive/task_closure"
require "hive/implementation_identity/resolver"
require "hive/task_resolver"
require "hive/brainstorm_parser"
require "hive/gh"
require "hive/pr"
require "hive/process_kill"
require "hive/pid_file"
require "hive/status_projection"
require "hive/operational_action"
require "hive/operational_status"
require "hive/daemon/operational_snapshot"
require "hive/terminal_text"
require "hive/tui/views/hyperlink"
require "hive/events"
require "hive/warnings"

module Hive
  module Commands
    class Status
      include Hive::Schemas::EnvelopeEmitter
      attr_reader :next_retention_boundary

      AUTO_SCHEDULER_SNAPSHOT = Object.new.freeze
      # Stage dir whose `needs_input` rows carry a brainstorm Q&A file we
      # count unanswered questions from (issue #270).
      BRAINSTORM_STAGE_DIR = "2-brainstorm".freeze # coding-scoped: unanswered-question count only parses coding brainstorm.md
      # First stage at which a PR exists; `pr.md` is only read from this
      # stage onward (see `pr_url_for`). Named here, and the numeric
      # threshold derived from `Hive::Stages`, so inserting or reordering a
      # stage can't silently shift which stages read `pr.md`.
      OPEN_PR_STAGE_DIR = "5-open-pr".freeze # coding-scoped: PR metadata exists only in coding open-pr and later stages
      OPEN_PR_STAGE_INDEX = Hive::Stages.parse(OPEN_PR_STAGE_DIR).first
      # Width of the text-mode PR column (`#NNN`, right-justified). Sourced
      # from the shared `Hive::Pr::NUMBER_WIDTH` so the text and TUI
      # (`Hive::Tui::Views::TasksPane::PR_WIDTH`) surfaces can't drift on
      # PR-column width.
      TEXT_PR_WIDTH = Hive::Pr::NUMBER_WIDTH
      # Widest rendered id is `#NNNN` (5 cells); a single space separates
      # each column in the identity string `#id #PR display-name`.
      TEXT_ID_WIDTH = 5
      # Display-name budget inside the identity column. Hand-tuned — bump by
      # hand if names need more room.
      TEXT_NAME_ALLOWANCE = 36
      # Total visible width of the identity column (`#id #PR display-name`).
      # Derived from TEXT_PR_WIDTH (hence Hive::Pr::NUMBER_WIDTH) so a
      # PR-column-width bump widens this budget in lockstep with the PR cell
      # instead of silently misaligning `hive status` text output. The id and
      # name terms are hand-tuned and bump by hand.
      TEXT_IDENTITY_WIDTH = TEXT_ID_WIDTH + 1 + TEXT_PR_WIDTH + 1 + TEXT_NAME_ALLOWANCE

      ICON = {
        none: "·",
        waiting: "⏸",
        complete: "✓",
        agent_working: "🤖",
        manual_steering: "🛠",
        execute_waiting: "⏸",
        execute_complete: "✓",
        execute_stale: "⚠",
        review_working: "🤖",
        review_waiting: "⏸",
        review_ci_stale: "⚠",
        review_stale: "⚠",
        review_complete: "✓",
        review_error: "⚠",
        error: "⚠"
      }.freeze

      OPERATIONAL_BANDS = [
        [ "running", "RUNNING" ],
        [ "waiting_on_you", "WAITING ON YOU" ],
        [ "needs_repair", "NEEDS REPAIR" ],
        [ "waiting_on_provider_or_scheduler", "WAITING ON PROVIDER / SCHEDULER" ],
        [ "completion_ready", "COMPLETION READY" ],
        [ "unknown", "UNKNOWN" ],
        [ "idle", "READY / IDLE" ]
      ].freeze
      OPERATIONAL_BAND_LIMIT = 5
      ADDITIVE_PATROL_FIX_ACTIONS = %w[
        patrol_fix_rejected patrol_fix_blocked patrol_fix_escalated
      ].freeze

      def initialize(json: false, diagnose: nil, project: nil, stage: nil, write: false, force: false, archive: false,
                     operational: false, full: false, daemon_tasks: nil, warning_sink: nil)
        @json = json
        @diagnose = diagnose
        @project = project
        @stage = stage
        @write = write
        @force = force
        @archive = archive
        @operational = operational
        @full = full
        @daemon_tasks = Array(daemon_tasks).compact
        @warning_sink = warning_sink
        @next_retention_boundary = nil
      end

      def warn(message)
        Hive::Warnings.emit(message, sink: @warning_sink)
      end
      private :warn

      def call
        call_with_envelope do
          validate_mode_combinations!
          if @diagnose && @diagnose.to_s.strip.empty?
            raise Hive::Error, "--diagnose requires a non-empty task slug"
          end
          if @write && @diagnose.nil?
            raise Hive::Error, "--write requires --diagnose <task>"
          end
          @diagnose ? diagnose_call : do_call
        end
      end

      def envelope_schema
        status_schema_for_call
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      def envelope_serialization_failure_policy = :suppress

      # `--diagnose` routes through diagnose_call which emits the
      # `hive-status-diagnose` envelope on success; the top-level rescue
      # must match the same schema so consumers can validate either
      # branch against `urn:hive:schema:status-diagnose:v1`. Explicit
      # operational and internal task-graph modes retain their own contracts; plain
      # `hive status --json` is the bounded running-status document.
      def status_schema_for_call
        return "hive-status-diagnose" if @diagnose
        return "hive-operational-status" if @operational
        return "hive-status" if @full || @archive || daemon_task_mode?

        "hive-running-status"
      end

      def do_call
        projects = Hive::Config.registered_projects
        refresh_now = Time.now.utc
        if daemon_task_mode?
          puts JSON.generate(daemon_task_payload(projects, now: refresh_now))
          @stdout_written = true
          return
        end
        if @operational
          payload = operational_payload(projects, now: refresh_now)
          if @json
            puts JSON.generate(payload)
            @stdout_written = true
          else
            render_operational(payload)
          end
          return
        end
        if @full || @archive
          if @json
            puts JSON.generate(json_payload(projects, now: refresh_now))
            @stdout_written = true
          else
            render_full(projects, now: refresh_now)
          end
          return
        end

        payload = running_payload(projects, now: refresh_now)
        if @json
          puts JSON.generate(payload)
          @stdout_written = true
        else
          render_running(payload)
        end
      end

      # Internal object boundary used by the long-lived daemon. It returns the
      # exact task-graph document without spawning another Ruby process or
      # serializing the graph through JSON only to parse it again.
      def internal_task_graph_payload(now: Time.now.utc)
        Hive::Warnings.with_sink(@warning_sink) do
          projects = Hive::Config.registered_projects
          if daemon_task_mode?
            daemon_task_payload(projects, now: now)
          else
            json_payload(projects, now: now)
          end
        end
      end

      def render_full(projects, now:)
        if projects.empty?
          puts "(no projects registered; run `hive init <path>`)"
          return
        end

        workflow_generations = capture_workflow_generations(projects)
        admission_context = build_admission_context(
          projects, workflow_generations: workflow_generations
        )
        owns_attempt_store = acquire_status_attempt_store
        projects.each do |project|
          render_project(
            project, project_count: projects.size,
            admission_context: admission_context, now: now,
            workflow_generation: workflow_generation_for(project, workflow_generations)
          )
        rescue Hive::UnsupportedProjectConfigError
          raise
        rescue StandardError => e
          # Symmetry with the JSON path's project_payload_or_degraded: isolate
          # per-project failures so one project (e.g. a malformed workflow
          # descriptor or config) doesn't blank text `status` for every other
          # project. Degrade to a one-line breadcrumb and keep rendering the rest.
          warn "hive: status: project #{project['name'].inspect} failed to render " \
               "(#{e.class}: #{e.message}); skipping it so other projects still display"
          puts "#{project['name']}: failed to load (#{e.message})"
        end
      ensure
        @status_attempt_store = nil if owns_attempt_store
      end

      def operational_payload(projects, scheduler_snapshot: AUTO_SCHEDULER_SNAPSHOT, status_payload: nil,
                              now: Time.now.utc)
        operational_status(
          projects,
          scheduler_snapshot: scheduler_snapshot,
          status_payload: status_payload,
          now: now
        ).to_h
      end

      def running_payload(projects, now: Time.now.utc)
        require "hive/running_status"
        Hive::RunningStatus.new.payload(projects, now: now)
      end

      def render_running(payload)
        render_runtime_identity(payload["runtime"])
        daemon = payload.fetch("daemon")
        if daemon.fetch("running")
          details = []
          details << "pid=#{daemon['pid']}" if daemon["pid"]
          details << "uptime=#{daemon['uptime_sec']}s" if daemon["uptime_sec"]
          suffix = details.empty? ? "" : " · #{details.join(' · ')}"
          puts "DAEMON RUNNING#{suffix}"
        else
          puts "DAEMON STOPPED"
        end

        rows = payload.fetch("tasks")
        if rows.empty?
          puts "NO RUNNING TASKS"
        else
          puts "RUNNING #{rows.length}"
          rows.each { |row| puts running_row_line(row) }
        end

        return if payload.fetch("complete")

        source = payload.fetch("source")
        reasons = []
        reasons << "scan limit reached" if source["scan_truncated"]
        reasons << "#{source['projects_unavailable']} projects unavailable" if source["projects_unavailable"].to_i.positive?
        reasons << "#{source['malformed_locks']} malformed locks" if source["malformed_locks"].to_i.positive?
        reasons << "#{source['transition_skips']} transitions skipped" if source["transition_skips"].to_i.positive?
        reasons << "#{payload['omitted_count']} live rows omitted" if payload["omitted_count"].to_i.positive?
        reasons << "source incomplete" if reasons.empty?
        puts "STATUS PARTIAL — #{reasons.join('; ')}"
      end

      def running_row_line(row)
        project = terminal_safe(row["project"])
        slug = terminal_safe(row["slug"])
        display_name = terminal_safe(row["display_name"])
        identity = "#{project}:#{slug}"
        identity = "#{identity} (#{display_name})" unless display_name.empty? || display_name == slug
        stage = terminal_safe(row["stage"])
        source = terminal_safe(row.dig("liveness", "source") || "verified_process")
        "  #{identity} · #{stage} · #{source}"
      end

      # Canonical recovery receipts for adapters that already hold a current
      # status graph. Unlike #operational_payload, this does not build task
      # classifications, reasons, actions, summaries, or archive metadata.
      def operational_recoveries(projects, scheduler_snapshot: AUTO_SCHEDULER_SNAPSHOT, status_payload: nil)
        operational_status(
          projects,
          scheduler_snapshot: scheduler_snapshot,
          status_payload: status_payload
        ).recovery_rows
      end

      def render_operational(payload)
        render_runtime_identity(payload["runtime"])
        summary = payload.fetch("summary")
        completeness = %w[complete partial unknown].include?(payload["completeness"]) ?
          payload.fetch("completeness") : "unknown"
        heading = "SNAPSHOT #{completeness.upcase} — " \
                  "#{summary.fetch('active')} active · #{summary.fetch('archived')} archived"
        task_graph = payload.dig("source", "task_graph") || {}
        if task_graph["provenance"] == "daemon_cache"
          heading += " · task graph cached #{task_graph.fetch('age_seconds').round}s ago"
        end
        puts heading
        hidden_count = summary.fetch("hidden_archived_task_count", 0)
        render_archived_hidden_summary(hidden_count) if hidden_count.positive?
        render_operational_issues(payload.fetch("issues"))

        if completeness == "complete" && summary.fetch("active").zero?
          render_operational_empty_state(payload)
          return
        end

        grouped = payload.fetch("tasks").group_by { |row| row.fetch("state") }
        OPERATIONAL_BANDS.each do |state, label|
          rows = Array(grouped[state]).sort_by do |row|
            [ row.dig("identity", "project").to_s, row.dig("identity", "slug").to_s ]
          end
          next if rows.empty?

          puts label
          rows.first(OPERATIONAL_BAND_LIMIT).each { |row| puts operational_row_line(row) }
          overflow = rows.size - OPERATIONAL_BAND_LIMIT
          puts "  +#{overflow} more — run `hive tui`" if overflow.positive?
        end
      end

      def validate_mode_combinations!
        if daemon_task_mode? && (!@json || !@full || @diagnose || @project || @stage || @write || @force ||
                                 @archive || @operational)
          raise Hive::InvalidTaskPath,
                "--daemon-task is internal and requires --internal-task-graph --json"
        end
        if @full && @operational
          raise Hive::InvalidTaskPath,
                "--internal-task-graph cannot be combined with --operational"
        end
        if (@full || @operational) && (@diagnose || @write || @force)
          mode = @full ? "--internal-task-graph" : "--operational"
          raise Hive::InvalidTaskPath,
                "#{mode} cannot be combined with --diagnose, --write, or --force"
        end
      end

      def render_runtime_identity(runtime)
        return unless runtime.is_a?(Hash)

        channel = runtime["channel"].to_s
        return if channel.empty? || channel == "release"

        details = [ terminal_safe(runtime["display_version"]) ]
        details << "sha=#{terminal_safe(runtime['build_sha'])}" unless runtime["build_sha"].to_s.empty?
        unless runtime["deployment_id"].to_s.empty?
          details << "deployment=#{terminal_safe(runtime['deployment_id'])}"
        end
        puts "HIVE #{terminal_safe(channel).upcase} · #{details.join(' · ')}"
      end

      def daemon_task_mode?
        !@daemon_tasks.empty?
      end

      def render_operational_issues(issues)
        Array(issues).each do |entry|
          message = terminal_safe(entry.fetch("message", "status source is incomplete"))
          remediation = terminal_safe(entry["remediation"])
          if entry["code"] == "attempt_storage_degraded"
            puts "  ⚠ #{message}; #{remediation}"
            next
          end

          puts "  ⚠ #{message}"
          puts "    #{remediation}" unless remediation.empty?
        end
      end

      def render_operational_empty_state(payload)
        summary = payload.fetch("summary")
        if summary.fetch("projects_total").zero?
          puts "NO REGISTERED PROJECTS"
          puts "  run `hive init <path>` to register and initialize a project"
        elsif summary.fetch("archived").positive?
          puts "ARCHIVE ONLY — #{summary.fetch('archived')} archived task" \
               "#{summary.fetch('archived') == 1 ? '' : 's'}"
          puts "  run `hive archive` to inspect archived task details"
        else
          puts "IDLE — no active work"
        end
      end

      def operational_row_line(row)
        identity = row.fetch("identity")
        project = terminal_safe(identity["project"])
        slug = terminal_safe(identity["slug"])
        display_name = terminal_safe(identity["display_name"])
        target = "#{project}:#{slug}"
        target = "#{target} (#{display_name})" unless display_name.empty? || display_name == slug
        stage = terminal_safe(row.dig("position", "stage"))
        marker = terminal_safe(row.dig("position", "marker"))
        owner = terminal_safe(row["blocker_owner"] || "unknown")
        reason = terminal_safe(row["reason"] || "status reason unavailable")
        routing = row["routing"]
        route = if routing.is_a?(Hash)
          selected = terminal_safe(routing["selected_route"])
          selected.empty? ? " · routing #{terminal_safe(routing['reason'])}" : " · route #{selected}"
        else
          ""
        end
        review = operational_plan_review_token(row["plan_review"])
        "  #{target} · #{stage}/#{marker}#{route}#{review} · #{owner} — #{reason}"
      end

      def operational_plan_review_token(review)
        return "" unless review.is_a?(Hash)

        level = terminal_safe(review["effective_level"] || review["computed_level"] || "pending")
        state = terminal_safe(review["state"] || "unknown")
        coverage = review.fetch("coverage_counts", {})
        findings = review.fetch("finding_counts", {})
        open = findings.fetch("open_gated", 0).to_i + findings.fetch("open_manual", 0).to_i
        completed = coverage.fetch("completed", 0).to_i
        total = coverage.values.sum { |value| value.to_i }
        " · review #{level}/#{state} coverage=#{completed}/#{total} open=#{open}"
      end

      def terminal_safe(value)
        Hive::TerminalText.escape(value)
      end

      def operational_project_context(projects, workflow_generations: nil)
        projects.to_h do |project|
          enabled = begin
            generation = workflow_generation_for(project, workflow_generations) if workflow_generations
            config = if generation && !generation.is_a?(Exception)
              generation.config
            else
              Hive::Config.load(project.fetch("path"))
            end
            config&.dig("daemon", "enabled") == true
          rescue Hive::UnsupportedProjectConfigError
            raise
          rescue Hive::Error, SystemCallError
            false
          end
          [
            project.fetch("name"),
            {
              "daemon_enabled" => enabled
            }
          ]
        end
      end

      def operational_status(projects, scheduler_snapshot:, status_payload:, now: Time.now.utc)
        if scheduler_snapshot.equal?(AUTO_SCHEDULER_SNAPSHOT)
          scheduler_snapshot = Hive::Daemon::OperationalSnapshot::Reader.new.read(now: now)
        end
        cache = status_payload ? nil : current_status_cache(
          projects, scheduler_snapshot, now: now
        )
        source = status_payload || cache&.fetch("payload", nil)
        workflow_generations = capture_workflow_generations(projects) unless source
        source ||= json_payload(
          projects, now: now, workflow_generations: workflow_generations
        )
        project_context = operational_project_context(
          projects, workflow_generations: workflow_generations
        )
        runtime_identity = if cache
          Hive::RuntimeIdentity.parse(cache["runtime"]) || Hive::RuntimeIdentity.unknown
        else
          Hive::RuntimeIdentity.new.to_h
        end
        Hive::OperationalStatus.new(
          status_payload: source,
          project_context: project_context,
          scheduler_snapshot: scheduler_snapshot,
          status_payload_tick_sequence: cache&.fetch("tick_sequence", nil),
          runtime_identity: runtime_identity,
          now: now
        )
      end

      def current_status_cache(projects, snapshot, now:)
        return unless snapshot.is_a?(Hash)
        return unless %w[current unavailable].include?(snapshot["status"])

        cache = status_cache_record(snapshot, now: now)
        return unless cache.is_a?(Hash)
        sequence = cache["tick_sequence"]
        snapshot_sequence = snapshot["tick_sequence"]
        return unless sequence.is_a?(Integer) && sequence.positive? &&
                      snapshot_sequence.is_a?(Integer) && sequence <= snapshot_sequence
        return if Time.iso8601(cache.fetch("valid_until")) < now

        payload = cache.fetch("payload")
        current_version = Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status")
        return unless payload.is_a?(Hash) && payload["schema"] == "hive-status" &&
                      payload["schema_version"] == current_version && payload["ok"] == true &&
                      payload["projects"].is_a?(Array)
        Time.iso8601(payload.fetch("generated_at"))
        return unless project_identities(payload.fetch("projects")) == project_identities(projects)

        cache
      rescue ArgumentError, TypeError, KeyError
        nil
      end

      def status_cache_record(snapshot, now:)
        Hive::Daemon::OperationalSnapshot::StatusCache::Reader.new.read(
          snapshot: snapshot, now: now
        )
      end

      def project_identities(projects)
        Array(projects).map do |project|
          [ project.fetch("name").to_s, File.expand_path(project.fetch("path").to_s) ]
        end.sort
      end

      # Stable schema for agent / wrapper consumption. Adding new keys is
      # non-breaking; removing or renaming keys must bump a documented
      # version. `tasks[].marker` is the lowercased symbol name as a string;
      # `tasks[].attrs` is the marker's attribute map.
      def json_payload(projects, stages: nil, exclude_archived: false, admission_context: nil,
                       now: Time.now.utc, workflow_generations: nil,
                       include_archive_index: false)
        owns_attempt_store = acquire_status_attempt_store
        now = now.utc
        @next_retention_boundary = nil
        workflow_generations ||= capture_workflow_generations(projects)
        # Dependency admission always sees the complete graph. Archive
        # retention is presentation-only: an expired completed prerequisite
        # must continue satisfying its dependants.
        admission_context ||= build_admission_context(
          projects, workflow_generations: workflow_generations
        )
        {
          "schema" => "hive-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
          "ok" => true,
          "generated_at" => now.iso8601(6),
          "projects" => projects.map do |p|
            project_payload_or_degraded(
              p,
              project_count: projects.size,
              stages: stages,
              exclude_archived: exclude_archived,
              admission_context: admission_context,
              now: now,
              workflow_generation: workflow_generation_for(p, workflow_generations),
              include_archive_index: include_archive_index
            )
          end
        }
      ensure
        @status_attempt_store = nil if owns_attempt_store
      end

      # Internal fast-tick payload. It resolves exact project/slug identities
      # without walking every task directory or rebuilding the fleet-wide
      # dependency graph. Rows with dependencies fail closed until the next
      # authoritative full scan.
      def daemon_task_payload(projects, now: Time.now.utc)
        targets = daemon_task_targets(projects)
        selected = projects.select { |project| targets.key?(project.fetch("name")) }
        workflow_generations = capture_workflow_generations(selected)
        owns_attempt_store = acquire_status_attempt_store
        {
          "schema" => "hive-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
          "ok" => true,
          "generated_at" => now.utc.iso8601(6),
          "partial" => true,
          "projects" => selected.map do |project|
            project_payload_or_degraded(
              project,
              project_count: projects.size,
              admission_context: nil,
              now: now.utc,
              workflow_generation: workflow_generation_for(project, workflow_generations),
              task_slugs: targets.fetch(project.fetch("name"))
            )
          end
        }
      ensure
        @status_attempt_store = nil if owns_attempt_store
      end

      # Isolate per-project failures. A single project with a malformed
      # config.yml (e.g. an invalid `dependency_gate_stage`) used to raise
      # out of `project_payload` and abort the daemon's internal task graph;
      # the daemon's StatusConsumer then reads `ok:false` and skips the
      # whole tick, freezing auto-advance fleet-wide. Degrade the offending
      # project to an empty task list (with a stderr breadcrumb in
      # daemon.log) so the rest of the fleet keeps advancing. The fallback
      # entry still validates against the published hive-status schema.
      def project_payload_or_degraded(project, project_count:, stages: nil, exclude_archived: false,
                                      admission_context: nil, now: Time.now.utc,
                                      workflow_generation: nil,
                                      include_archive_index: false, task_slugs: nil)
        project_payload(
          project,
          project_count: project_count,
          stages: stages,
          exclude_archived: exclude_archived,
          admission_context: admission_context,
          now: now,
          workflow_generation: workflow_generation,
          include_archive_index: include_archive_index,
          task_slugs: task_slugs
        )
      rescue Hive::UnsupportedProjectConfigError
        raise
      rescue StandardError => e
        warn "hive: status: project #{project['name'].inspect} payload failed " \
             "(#{e.class}: #{e.message}); reporting it with no tasks so other projects still advance"
        degraded = {
          "name" => project["name"],
          "path" => project["path"],
          "hive_state_path" => project["hive_state_path"],
          "error" => "project_load_failed",
          "tasks" => [],
          "legacy_stage_dirs" => [],
          "legacy_migrate_command" => nil
        }
        degraded["hidden_archived_task_count"] = 0 unless @archive
        degraded["__archive_folders"] = [] if include_archive_index
        degraded
      end

      def project_payload(project, project_count:, stages: nil, exclude_archived: false,
                          admission_context: nil, now: Time.now.utc,
                          workflow_generation: nil,
                          include_archive_index: false, task_slugs: nil)
        unless @status_attempt_store
          return with_status_attempt_store do
            project_payload(
              project,
              project_count: project_count,
              stages: stages,
              exclude_archived: exclude_archived,
              admission_context: admission_context,
              now: now,
              workflow_generation: workflow_generation,
              include_archive_index: include_archive_index,
              task_slugs: task_slugs
            )
          end
        end

        path = project["path"]
        hive_state = project["hive_state_path"]
        base = {
          "name" => project["name"],
          "path" => path,
          "hive_state_path" => hive_state
        }
        incremental = !task_slugs.nil?
        if !File.directory?(path)
          project_error_payload(base, "missing_project_path")
        elsif !File.directory?(hive_state)
          project_error_payload(base, "not_initialised")
        else
          # Hold the project overlay stable across load! + resolve: StatusFeed
          # runs this on both the poller thread and per-request threads, so a
          # concurrent load!(other project) must not clear THIS project's
          # overlay mid-resolve (which would make its custom-workflow rows
          # raise UnknownWorkflow and degrade the whole project). See
          # Hive::Workflows::Project::LOCK.
          Hive::Workflows::Project.synchronize do
            raise workflow_generation if workflow_generation.is_a?(Exception)
            Hive::Workflows::Project.load!(path) unless workflow_generation
            # JSON path: pay the diagnostic-extraction cost because
            # external consumers (TUI, daemon, bots) read `diagnostic` off
            # every row. Schema mandates the field.
            config = workflow_generation&.config || task_action_config(path)
            workflow_generation ||= Hive::Task.capture_workflow_generation(path, config: config)
            rows = annotate_implementation_identities(
              collect_rows(
                hive_state,
                stages: stages,
                exclude_archived: exclude_archived,
                now: now,
                workflow_generation: workflow_generation,
                project_name: project["name"],
                task_slugs: task_slugs
              ),
              config
            )
            rows = annotate_actions(
              rows,
              project, project_count, config: config, with_diagnostic: true
            )
            rows = if incremental
              annotate_incremental_dependencies(
                rows, project, config: config, workflow_generation: workflow_generation
              )
            else
              annotate_dependencies(rows, project, admission_context: admission_context)
            end
            projection = Hive::ArchiveFilter.project(
              rows, now: now,
              apply_retention: !@archive
            )
            note_retention_boundary(projection.next_retention_boundary) unless @archive
            rows =
              if @archive
                projection.archive_rows
              elsif exclude_archived
                projection.ordinary_rows.reject { |row| Hive::ArchiveFilter.archived_action?(row) }
              else
                projection.ordinary_rows
              end
            out = base.merge("tasks" => rows.map { |r| task_payload(r, now: now) })
            out["config_summary"] = {
              "stages" => {
                "ensure_clean_on_exit" =>
                  !config.is_a?(Hash) || config.dig("stages", "ensure_clean_on_exit") != false
              }
            }
            out["hidden_archived_task_count"] = incremental ? 0 : projection.hidden_count unless @archive
            if include_archive_index
              # Internal cache handoff only. StateSource removes this key
              # before publishing the ordinary payload, so the public status
              # schema and task objects remain unchanged.
              out["__archive_folders"] =
                projection.archive_rows.filter_map { |row| row[:folder] }.freeze
            end
            # Always emit `legacy_stage_dirs` (default empty array) so
            # consumers can branch on `.empty?` without a `key?` probe and
            # the schema's optional-but-never-undefined contract holds.
            legacy_stage_dirs = if incremental
              []
            else
              detect_legacy_stage_dirs(hive_state, workflow_generation: workflow_generation)
            end
            out["legacy_stage_dirs"] = legacy_stage_dirs
            # `legacy_migrate_command` is the machine-readable parity of the
            # text-mode "run `hive migrate`" recovery hint. Agents reading
            # the JSON envelope get a ready-to-execute command string when
            # legacy_stage_dirs is non-empty; `null` otherwise. The field is
            # always present (never absent) — same diagnostic-field
            # convention as `diagnostic` on tasks. Issue #94.
            out["legacy_migrate_command"] = legacy_stage_dirs.empty? ? nil : "hive migrate"
            out
          end
        end
      end

      def project_error_payload(base, error)
        payload = base.merge("error" => error, "tasks" => [])
        payload["hidden_archived_task_count"] = 0 unless @archive
        payload
      end

      # Scan `<hive_state>/stages/` for directories that are NOT in the
      # runtime union `Hive::Workflows.all_stage_dirs` (every registered
      # workflow's stage dirs) and contain at least one task-slug-shaped
      # subfolder. Returns `[{"stage_dir" => name, "task_count" => N},
      # ...]` sorted by name. `collect_rows` walks only `all_stage_dirs`, so
      # any stage rename (or a dropped workflow registration) leaves
      # pre-rename tasks unreachable from every operator surface — this is
      # the detector that turns that silent gap into a visible warning
      # instead. Only
      # `Hive::Stages.task_slug?` children count toward `task_count` so
      # stray `logs/`, `.DS_Store`, or `.gitkeep` siblings don't inflate
      # the number — the same predicate `Hive::Commands::Migrate` uses to
      # decide what it is allowed to mv, so the count matches what
      # `hive migrate` would actually move.
      STATUS_PRIVATE_STAGE_DIRS = %w[archived-manual].freeze

      def detect_legacy_stage_dirs(hive_state, workflow_generation: nil)
        stages_root = File.join(hive_state, "stages")
        return [] unless File.directory?(stages_root)

        Dir.children(stages_root).filter_map do |basename|
          next if workflow_stage_dirs(workflow_generation).include?(basename)
          next if STATUS_PRIVATE_STAGE_DIRS.include?(basename)

          dir = File.join(stages_root, basename)
          next unless File.directory?(dir)

          task_count = Dir.children(dir).count do |child|
            folder = File.join(dir, child)
            Hive::Stages.task_slug?(child) && File.directory?(folder) &&
              !managed_current_task?(folder, workflow_generation: workflow_generation)
          end
          next if task_count.zero?

          { "stage_dir" => basename, "task_count" => task_count }
        end.sort_by { |entry| entry["stage_dir"] }
      end

      # Ignore an out-of-union managed task only when it already resolves
      # against the selected generation. Stale pins fail Task construction and
      # remain visible as migration blockers.
      def managed_current_task?(folder, workflow_generation: nil)
        meta = Hive::TaskMeta.read(folder)
        return false unless meta[:workflow] && meta[:workflow_commit] &&
                            meta[:workflow_manifest_digest]

        Hive::Task.new(folder, workflow_generation: workflow_generation)
        true
      rescue StandardError
        false
      end

      def task_payload(row, now: Time.now.utc)
        payload = {
          "stage" => row[:stage],
          "slug" => row[:slug],
          "id" => row[:id],
          "display_name" => row[:display_name],
          "depends_on" => row[:depends_on],
          "blocked_by" => row[:blocked_by],
          "dependency_stage" => row[:dependency_stage],
          "blocked" => row[:blocked] == true,
          "admission_error" => row[:admission_error]&.to_h,
          "folder" => row[:folder],
          "state_file" => row[:state_file],
          "worktree_path" => row[:worktree_path],
          "pr_url" => row[:pr_url],
          "marker" => row[:marker_name].to_s,
          "attrs" => row[:marker_attrs],
          "task_history_invalid" => row[:task_history_invalid] == true,
          "mtime" => row[:mtime].utc.iso8601(6),
          "observation_mtime" => (row[:observation_mtime] || row[:mtime]).utc.iso8601(6),
          "folder_mtime" => row[:folder_mtime].utc.iso8601(6),
          "age_seconds" => [ (now - row[:mtime]).to_i, 0 ].max,
          "claude_pid" => row[:claude_pid],
          "claude_pid_alive" => row[:claude_pid_alive],
          # Coerced to boolean so nil never leaks into JSON: live_task_lock is
          # a tri-state internally (nil = no lease, true/false = liveness),
          # but external consumers only need "is the runner still holding it"
          # and would have to handle JSON null otherwise. Additive field per
          # the SCHEMA_VERSIONS policy in lib/hive.rb — no version bump.
          "live_task_lock" => row[:live_task_lock] == true,
          "attempt_id" => row[:attempt_id],
          "task_generation" => row[:task_generation],
          "task_lock_pid" => row[:task_lock_pid],
          "task_lock_process_start_time" => row[:task_lock_process_start_time],
          "task_lock_id" => row[:task_lock_id],
          "condition_task_generation" => row.dig(:projection_data, "identity", "task_generation"),
          "commit_generation" => row.dig(:projection_data, "identity", "commit_generation"),
          "current_attempt" => row.dig(:projection_data, "identity", "attempt_id"),
          "conditions" => row.dig(:projection_data, "conditions", "current") || [],
          "condition_history" => row.dig(:projection_data, "conditions", "history") || [],
          "evidence" => row.dig(:projection_data, "evidence") || [],
          "condition_overrides" => row.dig(:projection_data, "condition_overrides") || [],
          "condition_gate" => row[:condition_gate],
          "condition_migration" => row[:condition_migration],
          "condition_provenance" => row.dig(:projection_data, "provenance") || {},
          "shadow_audit" => row.dig(:projection_data, "shadow_audit") || {},
          "closure" => row.dig(:projection_data, "closure"),
          "condition_warning" => row[:condition_warning],
          "plan_review" => row[:plan_review],
          "implementation_identity" => row[:implementation_identity],
          "auto_residue" => Hive::Events.clean_exit_summary(row[:folder]),
          # Count of still-unanswered brainstorm Q&A questions (issue #270).
          # 0 for every non-brainstorm / non-needs_input row. Lets an agent
          # or operator tell "the daemon is holding this brainstorm because
          # N answers are outstanding" apart from "genuinely waiting for a
          # first answer" or "broken" — the daemon's answers-pending gate
          # is otherwise only visible in daemon.log. Additive field per the
          # SCHEMA_VERSIONS policy in lib/hive.rb — no version bump (mirrors
          # `live_task_lock`).
          "unanswered_questions" => unanswered_question_count(row),
          "action" => versioned_action_key(row[:action_key]),
          "action_label" => row[:action_label],
          "suggested_command" => row[:suggested_command],
          "outcomes" => row[:outcomes] || [],
          "next_action" => row[:next_action],
          "diagnostic" => row[:diagnostic]
        }
        payload["workflow"] = row[:workflow].to_s if row.key?(:workflow) && !row[:workflow].nil?
        payload.delete("implementation_identity") unless row[:implementation_identity]
        if Hive::AgentLimit.held?(row[:marker_name], row[:marker_attrs])
          payload["held"] = Hive::AgentLimit.held_field(row[:marker_attrs])
        end
        payload
      end

      # Number of unanswered `### Q{n}.` slots in a brainstorm task's
      # `brainstorm.md`. Only meaningful for a `2-brainstorm` `needs_input`
      # row; everything else is 0 without touching disk. Degrades to 0 on
      # any read/parse error (status must never fail because a brainstorm
      # file is mid-write or malformed). Uses the shared, total
      # `Hive::BrainstormParser` — the same parser the daemon gate and the
      # bot answer-writer use, so the three never disagree.
      def unanswered_question_count(row)
        return 0 unless row[:action_key] == Hive::Schemas::TaskActionKind::NEEDS_INPUT
        # Only the coding `2-brainstorm` stage drives the `### Q{n}.` answer
        # flow; a generic workflow reusing the dir has no Q&A to count.
        return 0 unless Hive::Workflows.coding_id?(row[:workflow])
        return 0 unless row[:stage] == BRAINSTORM_STAGE_DIR

        path = row[:state_file]
        return 0 unless path && File.exist?(path)

        Hive::BrainstormParser.unanswered_questions(Hive::BrainstormParser.parse(path)).size
      rescue StandardError
        0
      end

      def versioned_action_key(action_key)
        return Hive::Schemas::TaskActionKind::NEEDS_INPUT if
          ADDITIVE_PATROL_FIX_ACTIONS.include?(action_key.to_s)

        action_key
      end

      def diagnose_call
        task = Hive::TaskResolver.new(
          @diagnose,
          project_filter: @project,
          stage_filter: @stage
        ).resolve
        marker = Hive::Markers.current(task.state_file)
        # Local renamed off the same-named method (marker_summary) it is the
        # result of, so the shadowing doesn't obscure intent at the call sites.
        marker_summary_text = marker_summary(marker)
        liveness = liveness_kwargs_for(task)
        config = Hive::Config.load(task.project_root)
        action = Hive::TaskAction.for(
          task, marker, config: config, project_name: project_name_for(task), **liveness
        )
        diagnostic = action.diagnostic

        if @write
          # Gate the agent spawn on a red recovery state (recover_review
          # / error / recover_execute). Green tasks produce a nil
          # diagnostic and there is nothing for the agent to diagnose —
          # spawning would burn LLM budget for no signal. See PR #84
          # review finding #1.
          if diagnostic.nil?
            raise Hive::Error,
                  "task #{task.slug} is not in a red recovery state — nothing to diagnose"
          end

          # Idempotency: short-circuit when a fresh agent-written
          # artifact already covers the current marker_signature. The
          # TaskAction.for call above already returned that artifact's
          # body inside `diagnostic` (source == "artifact" and
          # generated_by != "local"). Pass --force to re-spawn anyway.
          # See PR #84 review finding #21.
          if !@force && diagnostic["source"] == "artifact" && diagnostic["generated_by"] != "local"
            emit_diagnose_result(task, diagnostic, diagnostic["source_path"], marker_summary: marker_summary_text)
            return
          end

          require "hive/diagnosis_agent"
          result = Hive::DiagnosisAgent.run!(task: task, local_diagnostic: diagnostic)
          diagnostic = Hive::TaskAction.for(
            task, marker, config: config, project_name: project_name_for(task), **liveness
          ).diagnostic
          emit_diagnose_result(task, diagnostic, result[:path], marker_summary: marker_summary_text)
        else
          if diagnostic.nil?
            evidence = Hive::DiagnosticEvidence.summarize(
              folder: task.folder,
              marker_summary: marker_summary_text,
              state_file: task.state_file
            )
            diagnostic = evidence_diagnostic(task, marker, evidence) if evidence
          end
          emit_diagnose_result(task, diagnostic, nil, marker_summary: marker_summary_text)
        end
      end

      # Liveness inputs for TaskAction. Mirrors the per-row computation
      # in collect_rows so the diagnose surface classifies stale
      # AGENT_WORKING the same way the internal task graph and the TUI do.
      # Otherwise stale rows hit via `--diagnose <slug>` would report
      # diagnostic=nil and the `--write` path would refuse with "not
      # in a red recovery state."
      def liveness_kwargs_for(task)
        lock_holder = task_lock_holder(task)
        live_holder = live_task_lock_holder(lock_holder)
        claude_pid = claude_pid_from_lock(lock_holder)
        state_file = task.state_file
        mtime = File.exist?(state_file) ? File.mtime(state_file) : nil
        {
          pid_alive: claude_pid ? pid_alive?(claude_pid.to_i) : nil,
          state_file_mtime: mtime,
          agent_marker_grace_sec: agent_marker_grace_sec_from_config,
          live_task_lock: !live_holder.nil?
        }
      end

      def emit_diagnose_result(task, diagnostic, path, marker_summary: nil)
        if @json
          puts JSON.generate(
            "schema" => "hive-status-diagnose",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status-diagnose"),
            "ok" => true,
            "slug" => task.slug,
            "id" => task.id,
            "display_name" => task.display_name,
            "task_folder" => task.folder,
            "marker_summary" => marker_summary,
            # The authoritative task state file the marker_summary was read
            # from. Threaded so the bot's evidence fallback can pin the marker
            # tier's source_path to the SAME file (mirroring the CLI's
            # state_file: pin), instead of mislabelling whatever *.md it globs
            # first under an advanced folder.
            "state_file" => task.state_file,
            "diagnostic" => diagnostic,
            "path" => path
          )
          @stdout_written = true
        else
          if path
            puts "wrote #{path}"
          elsif diagnostic
            puts diagnostic["summary"]
            puts diagnostic["detail"]
          else
            puts "no diagnostic evidence on disk for #{task.slug}"
          end
        end
      end

      # The canonical NAME+attrs marker rendering (shared with the diagnostic
      # surfaces via Hive::Markers.summary, plan R-5), routed through redact for
      # symmetry with the rest of the diagnose payload — the field is emitted
      # raw into the envelope and only the bot re-feeds it through SecretPatterns
      # otherwise. Returns nil for the :none marker so a markerless task's
      # envelope reads `marker_summary: null` (not "NONE") and the evidence
      # resolver omits the prefix, matching its unsupplied-marker_summary path.
      def marker_summary(marker)
        summary = Hive::Markers.summary(marker)
        summary && Hive::SecretPatterns.redact(summary)
      end

      # Synthesizes the schema-governed Diagnostic shape (hive-status-diagnose
      # `diagnostic`) from on-disk evidence for the nil-diagnostic read path.
      # Keep these nine keys in sync with Hive::TaskAction::Diagnostic#to_h and
      # the published schema — a field added there must be mirrored here or this
      # branch emits an invalid envelope (guarded by a JSONSchemer round-trip in
      # status_diagnose_test.rb). The evidence `kind` tier picks the detail
      # prefix (Diagnostics:/Log:/Marker:) and the schema `source` value
      # (marker tier -> "marker", artifact tiers -> "artifact").
      def evidence_diagnostic(task, marker, evidence)
        kind = evidence.fetch(:kind)
        source = Hive::DiagnosticEvidence.source_kind(kind)
        raw_source_path = evidence.fetch(:source_path)
        # Redact the path-bearing fields (detail / source_path / artifact_paths)
        # for symmetry with the already-redacted summary and the canonical
        # Diagnostic#to_h. The source_path is server-controlled under
        # .hive-state/, so this is cheap defense-in-depth rather than a known
        # leak. The mtime stat below uses the RAW path so a (hypothetical)
        # redaction can't break the timestamp.
        source_path = raw_source_path && Hive::SecretPatterns.redact(raw_source_path)
        detail = Hive::SecretPatterns.redact("#{Hive::DiagnosticEvidence.source_label(kind)}: #{source_path}")
        {
          "summary" => evidence.fetch(:summary),
          # Cap like the canonical Diagnostic#to_h (truncate(detail, DETAIL_MAX))
          # so a pathologically long source_path can't emit an envelope that
          # fails the schema's own detail.maxLength.
          "detail" => Hive::DiagnosticHelpers.truncate(detail, Hive::TaskAction::Diagnostic::DETAIL_MAX),
          "source" => source,
          "source_path" => source_path,
          # [source_path].compact so a future artifact-kind tier returning a nil
          # source_path can't emit schema-invalid artifact_paths:[nil].
          "artifact_paths" => source == "artifact" ? [ source_path ].compact : [],
          "generated_by" => "local",
          "marker_signature" => Hive::TaskAction.marker_signature(marker),
          "suggested_next_action" => nil,
          "updated_at" => (safe_mtime(raw_source_path) || safe_mtime(task.state_file) || Time.now).utc.iso8601
        }
      end

      def safe_mtime(path) = Hive::DiagnosticHelpers.safe_mtime(path)

      def project_name_for(task)
        project = Hive::Config.registered_projects.find { |entry| entry["path"] == task.project_root }
        project ? project["name"] : File.basename(task.project_root)
      end

      def render_project(project, project_count:, admission_context: nil, now: Time.now.utc,
                         workflow_generation: nil)
        path = project["path"]
        unless File.directory?(path)
          puts "#{project['name']}: missing project path #{path}"
          return
        end
        hive_state = project["hive_state_path"]
        unless File.directory?(hive_state)
          puts "#{project['name']}: not initialised (no .hive-state)"
          return
        end

        projection = nil
        Hive::Workflows::Project.synchronize do
          raise workflow_generation if workflow_generation.is_a?(Exception)
          Hive::Workflows::Project.load!(path) unless workflow_generation
          # Text-mode renders icon / state_label / suggested_command / age
          # only — `diagnostic` is unused here, so skip the bounded file-
          # I/O that TaskAction#diagnostic performs per red row. JSON path
          # still pays the full cost via project_payload.
          config = workflow_generation&.config || task_action_config(path)
          workflow_generation ||= Hive::Task.capture_workflow_generation(path, config: config)
          rows = annotate_implementation_identities(
            collect_rows(
              hive_state, now: now, workflow_generation: workflow_generation,
              project_name: project["name"]
            ),
            config
          )
          rows = annotate_actions(
            rows, project, project_count,
            config: config, with_diagnostic: false
          )
          rows = annotate_dependencies(rows, project, admission_context: admission_context)
          projection = Hive::ArchiveFilter.project(
            rows, now: now,
            apply_retention: !@archive
          )
        end
        if @archive
          render_archive_project(project, projection.archive_rows)
          return
        end

        visible_rows = projection.ordinary_rows
        hidden_count = projection.hidden_count
        legacy = detect_legacy_stage_dirs(hive_state, workflow_generation: workflow_generation)
        puts project["name"]
        render_legacy_stage_warning(legacy) unless legacy.empty?
        if visible_rows.empty? && hidden_count.zero?
          puts "  no active tasks" if legacy.empty?
          return
        end

        action_labels(visible_rows).each do |label|
          stage_rows = visible_rows.select { |r| r[:action_label] == label }
          next if stage_rows.empty?

          puts "  #{label}"
          stage_rows.sort_by { |r| -r[:mtime].to_i }.each do |r|
            command = r[:suggested_command] || "-"
            state = [
              r[:state_label], plan_review_status_token(r[:plan_review]),
              dependency_indicator(r), implementation_owner_token(r)
            ].compact.join(" ")
            puts "    #{r[:icon]} #{display_identity_with_pr(r, TEXT_IDENTITY_WIDTH)} " \
                 "#{state.ljust(24)} #{command} #{r[:age]}"
          end
        end
        render_archived_hidden_summary(hidden_count) if hidden_count.positive?
      end

      def render_archive_project(project, rows)
        puts project["name"]
        if rows.empty?
          puts "  no archived tasks"
          return
        end

        puts "  Archived"
        rows.sort_by { |row| -row[:mtime].to_i }.each do |row|
          command = row[:suggested_command] || "-"
          state = [
            row[:state_label], plan_review_status_token(row[:plan_review]),
            dependency_indicator(row), implementation_owner_token(row)
          ].compact.join(" ")
          puts "    #{row[:icon]} #{display_identity_with_pr(row, TEXT_IDENTITY_WIDTH)} " \
               "#{state.ljust(24)} #{command} #{row[:age]}"
        end
      end

      def plan_review_status_token(review)
        return nil unless review.is_a?(Hash)

        level = review["effective_level"] || review["computed_level"] || "pending"
        coverage = review.fetch("coverage_counts", {})
        findings = review.fetch("finding_counts", {})
        total = coverage.values.sum { |value| value.to_i }
        open = findings.fetch("open_gated", 0).to_i + findings.fetch("open_manual", 0).to_i
        "review=#{level}/#{review['state']} cov=#{coverage.fetch('completed', 0)}/#{total} open=#{open}"
      end

      def archive_rows(rows)
        rows.select { |row| Hive::ArchiveFilter.archive_row?(row) }
      end

      def render_archived_hidden_summary(hidden_count)
        noun = hidden_count == 1 ? "task" : "tasks"
        puts "  … and #{hidden_count} older archived #{noun} (hive archive to view)"
      end

      # Identity column = `#id  #PR display-name`, padded to `width` visible
      # cells. The OSC8 hyperlink for the PR token is spliced in AFTER the
      # padding (plan U3: "pad the plain token first, then wrap") because
      # String#ljust counts the OSC 8 framing (~14 bytes) plus the full URL
      # — 50+ invisible bytes, and URL-length-dependent — and would
      # otherwise add zero padding in a TTY, collapsing every column to the
      # right of the task name. NOTE: this method uses plain String#ljust/
      # rjust (char-counting), not the cell-aware Format.rjust_cells the TUI
      # uses, so a wide/CJK display_name would misalign the text column — a
      # known limitation, acceptable because the columns spliced here (`#id`
      # and the `#NNN` PR cell) are ASCII. The PR token sits at a fixed
      # offset (`#id ` + rjust padding), so Hyperlink.splice targets the PR
      # cell by offset rather than a global `sub` — clearer, no per-row regex
      # compile, no backreference footgun, and the offset always targets the
      # PR cell rather than any digits inside the name.
      def display_identity_with_pr(row, width)
        id = row[:id] ? "##{row[:id]}" : "—"
        token = Hive::Pr.number(row[:pr_url]) || "—"
        pr_cell = token.rjust(TEXT_PR_WIDTH)
        name = row[:display_name] || row[:slug]
        padded = "#{id} #{pr_cell} #{name}".ljust(width)
        return padded if token == "—"

        token_start = id.length + 1 + (pr_cell.length - token.length)
        Hive::Tui::Views::Hyperlink.splice(padded, token_start, token.length, row[:pr_url], enabled: $stdout.tty?)
      end

      def dependency_indicator(row)
        return nil unless row[:blocked]
        if row[:admission_error]
          error = row[:admission_error]
          return "⚠ admission #{error.reason_code}: #{error.safe_correction}"
        end

        # Shared with the TUI's renderer so the unresolved-vs-resolved
        # discriminator (blocked_by presence) can never diverge between
        # text mode and the TUI. See Hive::Dependencies.blocked_label.
        Hive::Dependencies.blocked_label(
          depends_on: row[:depends_on],
          blocked_by: row[:blocked_by],
          dependency_stage: row[:dependency_stage]
        )
      end

      # Build the public ownership view exclusively from the read-only task
      # projection. Missing downstream launches are previews resolved from
      # the immutable execute record plus raw configuration provenance; this
      # method never reconstructs legacy state or appends journal events.
      def annotate_implementation_identities(rows, config)
        rows.each do |row|
          next if row[:invalid]
          next unless Hive::Workflows.coding_id?(row[:workflow])

          row[:implementation_identity] = implementation_identity_status(
            row.dig(:projection_data, "implementation_identity"), config
          )
        end
      end

      def implementation_identity_status(projected, config)
        projected ||= {}
        generation = projected["generation"] || 0
        execute = projected["execute"]
        return { "generation" => generation, "pending" => true, "stages" => {} } unless execute

        stages = { "execute" => public_identity_stage(execute, status: "resolved") }
        resolver = Hive::ImplementationIdentity::Resolver.new(cfg: config)
        %w[open_pr review.fix review.ci].each do |stage|
          actual = projected.dig("stages", stage)
          identity = actual || resolver.resolve_stage(stage, execute_identity: execute)
          stages[stage] = public_identity_stage(identity, status: actual ? "resolved" : "preview")
        rescue Hive::ImplementationIdentity::Error, Hive::ConfigError => e
          stages[stage] = {
            "status" => "resolution_error",
            "source" => implementation_preview_source(config, stage, execute),
            "resolution_error" => e.message.to_s[0, 240]
          }
        end
        { "generation" => generation, "pending" => false, "stages" => stages }
      end

      def public_identity_stage(identity, status:)
        value = identity.respond_to?(:to_h) ? identity.to_h : identity
        public_value = {
          "provider" => value["provider"],
          "model" => value["model"],
          "requested_effort" => value["requested_effort"],
          "effective_effort" => value["effective_effort"],
          "effort_supported" => value["effort_supported"] == true,
          "source" => value["source"],
          "originating_attempt" => value["originating_attempt"],
          "resolved_attempt" => value["resolved_attempt"],
          "status" => status
        }
        %w[
          requested_backend requested_model actual_backend actual_model
          route_resolution_status outcome_kind usage observed_attempt
        ].each do |key|
          public_value[key] = value[key] if value.key?(key)
        end
        public_value
      end

      def implementation_preview_source(config, stage, execute)
        fields = config ? Hive::Config.implementation_identity_fields(config, stage) : {}
        return "explicit_override" unless fields.empty?

        execute["source"] == "legacy_backfill" ? "legacy_backfill" : "persisted_execute"
      end

      # Bounded token appended after the primary state/dependency signals, so
      # a narrow text or TUI column truncates ownership before it hides the
      # operational state that tells the operator what to do next.
      def implementation_owner_token(row)
        identity = row.dig(:implementation_identity, "stages", "execute")
        return nil unless identity && identity["provider"] && identity["model"]

        model = identity["model"].to_s
        model = "#{model[0, 11]}…" if model.length > 12
        "owner=#{identity['provider']}/#{model}"
      end

      def render_legacy_stage_warning(legacy)
        total = legacy.sum { |entry| entry["task_count"] }
        dirs = legacy.map { |entry| "#{entry['stage_dir']} (#{entry['task_count']})" }.join(", ")
        puts "  ⚠ #{total} task#{total == 1 ? '' : 's'} hidden in legacy stage dirs: #{dirs}"
        puts "    run `hive migrate` to move them into the current layout"
      end

      # Stage dirs to walk when no explicit `stages:` list is given are
      # computed from `Hive::Workflows.all_stage_dirs` AT CALL TIME. For
      # the TUI's active-only re-parse this runs INSIDE the per-project
      # `Workflows::Project.synchronize { load!(path); ... }` block, so a
      # project's custom-workflow active stages are honored instead of
      # being dropped by a union pre-computed against a different project's
      # overlay. Archive membership is applied after TaskAction annotation,
      # because one workflow's terminal directory may be another workflow's
      # active directory.
      def default_stage_dirs(hive_state, exclude_archived, workflow_generation: nil)
        # Archive membership is workflow/action-aware and cannot be inferred
        # from a global terminal-directory union. The normal producer scans the
        # full generation. The TUI's explicitly active-only hot path scans the
        # union of nonterminal stages for the captured project generation and
        # merges the last authoritative retention projection afterward.
        stages_root = File.join(hive_state, "stages")
        selected_stage_dirs =
          if exclude_archived
            workflow_active_stage_dirs(workflow_generation)
          else
            workflow_stage_dirs(workflow_generation)
          end
        on_disk = Dir.children(stages_root).select do |entry|
          entry.match?(/\A\d+-[a-z][a-z0-9-]*\z/) &&
            File.directory?(File.join(stages_root, entry)) &&
            (selected_stage_dirs.include?(entry) ||
             (!exclude_archived &&
             orphan_stage_has_workflow_reference?(
               File.join(stages_root, entry), workflow_generation: workflow_generation
             )))
        end
        (selected_stage_dirs + on_disk).uniq
      rescue SystemCallError
        selected_stage_dirs || workflow_stage_dirs(workflow_generation)
      end

      def orphan_stage_has_workflow_reference?(stage_dir, workflow_generation: nil)
        task_folders = Dir.children(stage_dir).filter_map do |child|
          folder = File.join(stage_dir, child)
          folder if Hive::Stages.task_slug?(child) && File.directory?(folder)
        end
        return false if task_folders.empty?
        return true if task_folders.any? { |folder| Hive::TaskMeta.read(folder)[:workflow] }

        # Fieldless legacy tasks follow the project default. Keep their orphan
        # stage visible when that default descriptor was deleted or could not be
        # registered, just as an explicitly pinned broken workflow remains
        # visible above.
        hive_state = File.dirname(File.dirname(stage_dir))
        project_root = File.dirname(hive_state)
        _, raw_config = Hive::Config.read_project_config(project_root)
        default_workflow = raw_config["default_workflow"].to_s.strip
        !default_workflow.empty? &&
          !workflow_ids(workflow_generation).include?(default_workflow.to_sym)
      rescue Hive::ConfigError, SystemCallError
        false
      end

      def collect_rows(hive_state, stages: nil, exclude_archived: false, now: Time.now.utc,
                       workflow_generation: nil, project_name: nil, task_slugs: nil)
        unless @status_attempt_store
          return with_status_attempt_store do
            collect_rows(
              hive_state, stages: stages, exclude_archived: exclude_archived, now: now,
              workflow_generation: workflow_generation, project_name: project_name,
              task_slugs: task_slugs
            )
          end
        end

        rows = []
        known_stage_dirs = workflow_stage_dirs(workflow_generation)
        terminal_stage_dirs = workflow_terminal_stage_dirs(workflow_generation)
        selected_stages = if stages
          stages
        elsif task_slugs
          workflow_stage_dirs(workflow_generation)
        else
          default_stage_dirs(
            hive_state, exclude_archived, workflow_generation: workflow_generation
          )
        end
        Array(selected_stages).each do |stage|
          stage_dir = File.join(hive_state, "stages", stage)
          next unless File.directory?(stage_dir)

          entries = if task_slugs
            task_slugs.map { |slug| File.join(stage_dir, slug) }
          else
            stage_task_entries(stage_dir)
          end
          entries.each do |entry|
            next unless File.directory?(entry)

            slug = File.basename(entry)
            begin
              begin
                task = Hive::Task.new(entry, workflow_generation: workflow_generation)
              rescue Hive::UnsupportedProjectConfigError
                raise
              rescue Hive::InvalidTaskPath, Hive::ConfigError => e
                # U6 widened this rescue's blast radius: a typo'd
                # `meta.yml workflow:` / `config.yml default_workflow:` or a
                # stage-dir/workflow mismatch now raises in Task.new. Silently
                # skipping it once vanished a real task from `hive status` (and
                # the daemon) — and a typo'd PROJECT default emptied the WHOLE
                # project to zero rows. Surface a synthetic Error row in the
                # payload so the breakage is observable to the daemon/UI, not
                # just on stderr. Stray non-slug dirs stay silent (skipped).
                next unless Hive::Stages.task_slug?(slug)

                warn "hive: status: #{entry} failed to load (#{e.message}); surfaced as an Error row"
                rows << invalid_task_row(
                  stage: stage, slug: slug, folder: entry, message: e.message, now: now,
                  archive_member: terminal_stage_dirs.include?(stage) ||
                    !known_stage_dirs.include?(stage)
                )
                next
              end
              marker = if task.workflow.controller?
                Hive::Markers::State.new(name: :none, attrs: {}, raw: nil)
              else
                Hive::Markers.current(task.state_file)
              end
              marker, projection, task_history_invalid = status_projection(
                task, marker, project: project_name || project_name_for(task)
              )
              folder_mtime = File.mtime(entry)
              mtime = if task.workflow.controller?
                folder_mtime
              else
                File.exist?(task.state_file) ? File.mtime(task.state_file) : folder_mtime
              end
              # Generic markerless tasks still carry meta.yml. Use that stable
              # task-owned file for the action observation before falling back
              # to the directory mtime. Keep `mtime` on its long-standing
              # state-file/directory meaning because the daemon's dispatch
              # baseline relies on a stage move changing that value.
              #
              # The runtime lease is outside the task tree, so it does not
              # perturb the filesystem observation used by this action.
              observation_source = Hive::OperationalAction.observation_mtime_source(task)
              observation_mtime = observation_source == entry ? folder_mtime : File.mtime(observation_source)
              lock_holder = task_lock_holder(task)
              live_holder = live_task_lock_holder(lock_holder)
              icon, state_label = decorate(task, marker, lock_holder: lock_holder, live_task_lock: !live_holder.nil?)
              claude_pid = claude_pid_from_lock(lock_holder)
              # Resolve once per row so JSON consumers (bot / daemon / agents)
              # get the absolute worktree path without re-implementing the
              # branch.yml lookup. Pre-execute stages legitimately return
              # nil. See PR #84 review finding #8.
              worktree_path =
                begin
                  task.worktree_path
                rescue Hive::UnsupportedProjectConfigError
                  raise
                rescue StandardError
                  nil
                end
              rows << {
                stage: stage,
                slug: slug,
                id: task.id,
                display_name: task.display_name,
                workflow: task.workflow.id,
                depends_on: task.depends_on,
                folder: entry,
                state_file: task.state_file,
                worktree_path: worktree_path,
                pr_url: pr_url_for(task),
                task: task,
                marker_name: marker.name,
                marker_attrs: marker.attrs,
                task_history_invalid: task_history_invalid == true,
                projection: projection,
                projection_data: projection.to_h,
                icon: icon,
                state_label: state_label,
                mtime: mtime,
                observation_mtime: observation_mtime,
                folder_mtime: folder_mtime,
                age: humanise_age(mtime, now: now),
                claude_pid: claude_pid,
                claude_pid_alive: claude_pid ? pid_alive?(claude_pid.to_i) : nil,
                live_task_lock: !live_holder.nil?,
                attempt_id: lock_holder && lock_holder["attempt_id"],
                task_generation: lock_holder && lock_holder["task_generation"],
                task_lock_pid: live_holder && live_holder["pid"],
                task_lock_process_start_time: live_holder && live_holder["process_start_time"],
                task_lock_id: live_holder && live_holder["lock_id"]
              }
            # A mid-scan stage-move (atomic rename of <stage>/<slug> out from
            # under us) makes an in-folder read raise ENOENT even though the
            # :423 File.directory? guard already passed. The rescue wraps the
            # whole begin, so the ENOENT can surface from ANY in-folder read —
            # File.mtime(entry) at :433, Markers.current's File.exist?->File.read
            # (markers.rb:59-61), or the lease read in task_lock_holder — all of
            # which behave identically here. We swallow it and `next`: on a
            # forward stage-move the task resurfaces under its new (higher-
            # numbered) stage later in this same scan, and
            # drop_transient_stage_moves prunes any stale duplicate. A backward
            # move (higher stage -> already-scanned lower stage) instead just
            # drops the row for one frame and it reappears on the next poll — no
            # correctness impact, only a one-frame glitch (out of plan scope).
            #
            # The `raise if File.directory?(entry)` re-check preserves the
            # corrupted-but-present -> Error path. If the folder still exists at
            # rescue time, the ENOENT came from genuine in-folder corruption
            # (e.g. a state file removed out of band), NOT a stage move, so we
            # let it propagate (exit-70). The safety premise is folder-level, not
            # write-level: the ONLY thing that makes `entry` (the folder) vanish
            # is an atomic stage-move rename — in-place file writers never make
            # the folder disappear, and they never leave the state file
            # transiently *absent* inside a surviving folder either. Plain
            # File.write callers (execute.rb, open_pr.rb, babysitter/pr_fixer.rb)
            # open O_CREAT|O_TRUNC, truncating to zero *length*, never zero
            # *existence*, so File.mtime still succeeds; atomic-rename writers
            # (Markers.write_atomic) likewise always leave a file in place. Only
            # a future change that unlinked or renamed a *folder* out of band
            # would break that premise and reintroduce a process-killing crash on
            # this poll-heavy surface. Pinned by
            # test_collect_rows_reraises_enoent_when_folder_survives and
            # test_collect_rows_reraises_enoent_from_state_file_mtime_when_folder_survives.
            #
            # Only Errno::ENOENT is rescued: local same-device .hive-state
            # renames always yield ENOENT. Other vanish errnos (ENOTDIR from a
            # path component flipping to a file, ESTALE from an NFS handle) are
            # deliberately NOT caught and propagate as exit-70.
            rescue Errno::ENOENT
              raise if File.directory?(entry)

              next
            end
          end
        end
        drop_transient_stage_moves(rows)
      end

      def status_projection(task, marker, project: nil)
        unless @status_attempt_store
          return with_status_attempt_store do
            status_projection(task, marker, project: project)
          end
        end

        attempt_store = status_attempt_store
        bounded = Hive::TaskProjection::Reader.new(
          task_folder: task.folder, task: task
        ).read_routine(marker: marker)
        project ||= project_name_for(task)
        case bounded.state
        when "invalid"
          task_history_invalid_status(task, bounded)
        when "busy"
          task_history_unavailable_status(task, bounded)
        when "current"
          projection = bounded.projection
          closure = Hive::TaskClosure.projection(
            task, project: project, attempt_store: attempt_store,
            task_projection: projection
          )
          projection = projection.with_closure(closure) if closure
          [ marker, projection, false ]
        else
          task_history_unavailable_status(task, bounded)
        end
      rescue Hive::TaskProjection::Error, Hive::TaskJournal::Error,
             SystemCallError, IOError => e
        project ||= project_name_for(task)
        bounded = Hive::TaskProjection::Reader::BoundedRead.new(
          projection: nil, state: "invalid", truncated: false,
          journal_cursor: 0, journal_records: [],
          diagnostics: [ {
            "source" => "task_journal", "reason" => "journal_read_failed",
            "message" => "task journal read failed",
            "details" => { "error_class" => e.class.name }
          } ]
        )
        task_history_invalid_status(task, bounded)
      end

      def task_history_invalid_status(task, bounded)
        attrs = Hive::TaskProjection.invalid_journal_marker_attrs(bounded: bounded)
        error_marker = Hive::Markers::State.new(name: :error, attrs: attrs, raw: nil)
        warn "hive: status: #{task.folder} task journal is invalid " \
             "(#{attrs.fetch('journal_reason')}); surfaced as a task-local Error row"
        [
          error_marker,
          Hive::TaskProjection.project(records: [], marker: error_marker),
          true
        ]
      end

      def task_history_unavailable_status(task, bounded)
        attrs = Hive::TaskProjection.unavailable_journal_marker_attrs(bounded: bounded)
        error_marker = Hive::Markers::State.new(name: :error, attrs: attrs, raw: nil)
        warn "hive: status: #{task.folder} task journal is temporarily unavailable " \
             "(#{attrs.fetch('journal_reason')}); retrying on the next scan"
        [
          error_marker,
          Hive::TaskProjection.project(records: [], marker: error_marker),
          false
        ]
      end

      def status_attempt_store
        @status_attempt_store || raise(Hive::Error, "status attempt store is outside a scan")
      end

      def with_status_attempt_store
        owns_store = acquire_status_attempt_store
        yield
      ensure
        @status_attempt_store = nil if owns_store
      end

      def acquire_status_attempt_store
        return false if @status_attempt_store

        @status_attempt_store = Hive::Attempts::Repository.open_default(
          create_directories: false
        ).read_session
        true
      end

      def annotate_dependencies(rows, project, admission_context: nil)
        context = admission_context || build_admission_context([ project ])
        rows.each { |row| apply_dependency_verdict(row, context, project) }
        rows
      end

      def annotate_incremental_dependencies(rows, project, config:, workflow_generation:)
        snapshots = rows.filter_map do |row|
          next if row[:invalid]

          Hive::DependencySnapshot.admission_task(
            project.fetch("path"), row.fetch(:folder), config,
            project_name: project.fetch("name"), workflow_generation: workflow_generation
          )
        end
        project_snapshot = Hive::DependencyAdmission::ProjectSnapshot.new(
          name: project.fetch("name"),
          path: project.fetch("path"),
          repository_identity: project["repository_identity"],
          live_repository_identity: nil,
          dependency_gate_stage: config.fetch(
            "dependency_gate_stage", Hive::Config::DEFAULTS.fetch("dependency_gate_stage")
          ),
          tasks: snapshots,
          validation_error: workflow_generation&.admission_config_error
        )
        context = Hive::DependencyAdmission::Context.new(projects: [ project_snapshot ])
        rows.each do |row|
          apply_dependency_verdict(row, context, project)
          hold_incremental_dependency(row, project) if row[:depends_on]
        end
        rows
      rescue StandardError => e
        warn "hive: status: bounded dependency admission failed " \
             "(#{e.class}: #{e.message}); holding changed rows until the next full scan"
        rows.each { |row| hold_incremental_dependency(row, project) }
        rows
      end

      def hold_incremental_dependency(row, project)
        error = Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "dependency_validation_failed",
          offending_ref: "#{project['name']}:#{row[:slug]}",
          safe_correction: "Wait for the daemon's next authoritative full dependency scan."
        )
        row[:blocked_by] = nil
        row[:dependency_stage] = nil
        row[:blocked] = true
        row[:admission_error] = error
        row[:action_key] = Hive::Schemas::TaskActionKind::ADMISSION_ERROR
        row[:action_label] = "Admission error"
        row[:suggested_command] = nil
        row[:next_action] = nil
      end

      def daemon_task_targets(projects)
        known = projects.to_h { |project| [ project.fetch("name"), project ] }
        @daemon_tasks.each_with_object({}) do |reference, targets|
          project_name, separator, slug = reference.to_s.partition(":")
          unless separator == ":" && known.key?(project_name) && Hive::Stages.task_slug?(slug)
            raise Hive::InvalidTaskPath,
                  "invalid --daemon-task #{reference.inspect}; expected registered-project:task-slug"
          end
          (targets[project_name] ||= []) << slug unless Array(targets[project_name]).include?(slug)
        end
      end

      def build_admission_context(projects, exclude_archived: false, workflow_generations: nil)
        Hive::DependencySnapshot.admission_context(
          projects, exclude_archived: exclude_archived,
          workflow_generations: workflow_generations
        )
      rescue Hive::UnsupportedProjectConfigError
        raise
      rescue StandardError => e
        warn "hive: status: dependency admission snapshot failed " \
             "(#{e.class}: #{e.message}); holding every affected row"
        snapshots = projects.map do |project|
          Hive::DependencyAdmission::ProjectSnapshot.new(
            name: project["name"].to_s,
            path: project["path"].to_s,
            repository_identity: project["repository_identity"],
            live_repository_identity: nil,
            dependency_gate_stage: Hive::Config::DEFAULTS.fetch("dependency_gate_stage"),
            tasks: [],
            validation_error: "#{e.class}: #{e.message}"
          )
        end
        Hive::DependencyAdmission::Context.new(projects: snapshots)
      end

      def capture_workflow_generations(projects)
        Array(projects).each_with_object({}) do |project, generations|
          path = project["path"]
          next unless path && File.directory?(path) && File.directory?(project["hive_state_path"])

          key = File.expand_path(path)
          generations[key] = Hive::Workflows::Project.synchronize do
            Hive::Workflows::Project.load!(path)
            config = task_action_config(path)
            admission_config, admission_config_error =
              Hive::DependencySnapshot.admission_project_config(path)
            Hive::Task.capture_workflow_generation(
              path, config: config,
              admission_config: admission_config,
              admission_config_error: admission_config_error
            )
          end
        rescue Hive::UnsupportedProjectConfigError
          raise
        rescue StandardError => e
          generations[key] = e if key
        end
      end

      def workflow_generation_for(project, workflow_generations)
        workflow_generations[File.expand_path(project.fetch("path"))]
      rescue KeyError, TypeError
        nil
      end

      def workflow_stage_dirs(generation)
        generation ? generation.stage_dirs : Hive::Workflows.all_stage_dirs
      end

      def workflow_active_stage_dirs(generation)
        return generation.active_stage_dirs if generation

        Hive::Workflows::Registry.all
          .flat_map { |workflow| workflow.stages[0...-1].map(&:dir) }
          .uniq
      end

      def workflow_terminal_stage_dirs(generation)
        generation ? generation.terminal_stage_dirs : Hive::Workflows.all_terminal_stage_dirs
      end

      def workflow_ids(generation)
        generation ? generation.workflows.keys : Hive::Workflows::Registry.ids
      end

      def note_retention_boundary(boundary)
        return unless boundary

        @next_retention_boundary = [ @next_retention_boundary, boundary ].compact.min
      end

      def apply_dependency_verdict(row, context, project)
        row[:archive_member] = Hive::ArchiveFilter.archived_action?(row) unless row.key?(:archive_member)
        verdict = context.verdict(project: project["name"], slug: row[:slug])
        row[:blocked_by] = verdict.wait? ? verdict.blocked_by : nil
        row[:dependency_stage] = verdict.wait? ? verdict.dependency_stage : nil
        row[:blocked] = verdict.blocked?
        row[:admission_error] = verdict.admission_error
        return unless verdict.error?

        row[:action_key] = Hive::Schemas::TaskActionKind::ADMISSION_ERROR
        row[:action_label] = "Admission error"
        row[:suggested_command] = nil
        row[:next_action] = nil
      rescue StandardError => e
        warn "hive: status: dependency admission failed for #{row[:slug].inspect} " \
             "(#{e.class}: #{e.message}); holding the row"
        error = Hive::DependencyAdmission::AdmissionError.new(
          reason_code: "dependency_validation_failed",
          offending_ref: "#{project['name']}:#{row[:slug]}",
          safe_correction: "Inspect project configuration and dependency metadata before retrying."
        )
        row[:blocked_by] = nil
        row[:dependency_stage] = nil
        row[:blocked] = true
        row[:admission_error] = error
        row[:action_key] = Hive::Schemas::TaskActionKind::ADMISSION_ERROR
        row[:action_label] = "Admission error"
        row[:suggested_command] = nil
        row[:next_action] = nil
      end

      def pr_url_for(task)
        # PR metadata (pr.md) is a coding-workflow artifact, written only from
        # the coding open-pr stage onward. Gate on the workflow so a generic
        # task reusing a >= 5 stage index isn't probed for a pr.md it never
        # writes — inert today (generic tasks have no pr.md → nil) but keeps the
        # coding PR gate from leaking onto generic rows.
        managed_draft_pr = task.workflow.draft_pr_handoff?
        unless managed_draft_pr
          return nil unless Hive::Workflows.coding_id?(task.workflow.id) # coding-scoped: PR metadata exists only in the coding workflow
          return nil if task.stage_index < OPEN_PR_STAGE_INDEX
        end

        value = Hive::Gh.pr_frontmatter(File.join(task.folder, "pr.md"))["pr_url"]
        value = value.to_s.strip
        value.empty? ? nil : value
      rescue Errno::ENOENT
        # pr.md vanished mid-scan — a TOCTOU race with a stage-move rename
        # (Hive::Gh.pr_frontmatter guards a missing file with File.exist?, so
        # a plain absent pr.md returns {} and never reaches here). Degrade to
        # "no PR"; the row's other in-folder reads in collect_rows handle a
        # genuine folder move via their own ENOENT contract.
        nil
      rescue SystemCallError => e
        # Any other I/O fault reading pr.md (EACCES/ENOTDIR/ESTALE/…): warn so
        # the inconsistency is visible (mirrors task_lock_holder's lease
        # reader) but still degrade rather than crash this poll-heavy
        # surface, preserving the plan's never-crash-on-bad-pr.md contract.
        # Narrowed from a blanket `rescue StandardError` so genuine
        # programmer errors (e.g. a NoMethodError if pr_frontmatter's return
        # shape changes) surface as exit-70 instead of being silently hidden.
        warn "hive: status: failed to read pr.md at #{File.join(task.folder, 'pr.md')}: #{e.class}: #{e.message}"
        nil
      end

      # The production glob over a stage dir's task folders, extracted into its
      # own method so the deterministic stage-move race tests can subclass and
      # override it (test StatusRaceCommand) to inject a mid-scan rename/vanish.
      # collect_rows is the sole caller.
      def stage_task_entries(stage_dir)
        Dir[File.join(stage_dir, "*")]
      end

      # Prune the stale half of a stage-move duplicate: when one slug shows up in
      # two stages because a rename landed mid-scan, drop the row whose folder no
      # longer exists. The predicate keys on slug + folder existence, NOT task
      # identity (inode / meta.yml id): a <stage>/<slug> path torn down and
      # recreated by a *different* task inside one scan window could momentarily
      # keep a row whose id/display_name no longer match the folder. That is
      # astronomically narrow under atomic renames and self-heals on the next
      # poll, so the slug-path identity assumption is intentional.
      def drop_transient_stage_moves(rows)
        duplicated_slugs = rows.group_by { |row| row[:slug] }.select { |_slug, group| group.size > 1 }
        return rows if duplicated_slugs.empty?

        rows.reject do |row|
          duplicated_slugs.key?(row[:slug]) && !File.directory?(row[:folder])
        end
      end

      def decorate(task, marker, lock_holder: nil, live_task_lock: false)
        if marker.name == :agent_working
          # Marker only carries the hive runner PID; the claude subprocess PID
          # is recorded in the task's runtime lease by Hive::Agent.
          pid = claude_pid_from_lock(lock_holder) || marker.attrs["pid"]
          if pid && pid_alive?(pid.to_i)
            [ "🤖", "agent_working pid=#{pid}" ]
          elsif live_task_lock
            pid = lock_holder && lock_holder["pid"]
            [ "🤖", pid ? "run_lock pid=#{pid}" : "run_lock" ]
          else
            [ "⚠", "stale lock pid=#{pid}" ]
          end
        elsif live_task_lock
          pid = lock_holder && lock_holder["pid"]
          [ "🤖", pid ? "run_lock pid=#{pid}" : "run_lock" ]
        else
          [ ICON.fetch(marker.name, "·"), label_for(marker) ]
        end
      end

      # Presentation ordering is owned by the internal status projection
      # boundary (`Hive::StatusProjection`); the command re-exports the
      # frozen constant so existing label-grouping call sites and tests
      # keep one shared value.
      ACTION_LABEL_ORDER = Hive::StatusProjection::ACTION_LABEL_ORDER

      # Synthetic Error row for a task folder that exists but won't load — e.g.
      # a typo'd `meta.yml workflow:` / project `default_workflow:` that resolves
      # to no registered descriptor. It carries no real Task object (`task: nil`,
      # `invalid: true`); annotate_actions stamps a fixed Error annotation and
      # annotate_dependencies treats it as unblocked, so the broken task shows
      # in the snapshot instead of being silently dropped. The load error lands
      # in `marker_attrs[:message]` (surfaced in the JSON row's `attrs`).
      def invalid_task_row(stage:, slug:, folder:, message:, now: Time.now.utc,
                           archive_member: false)
        folder_mtime =
          begin
            File.mtime(folder)
          rescue SystemCallError
            now
          end
        marker = Hive::Markers::State.new(
          name: :error,
          attrs: { "reason" => "invalid_task", "message" => message.to_s[0, 200] },
          raw: nil
        )
        icon, state_label = decorate(nil, marker)
        {
          invalid: true,
          archive_member: archive_member,
          stage: stage,
          slug: slug,
          id: nil,
          display_name: nil,
          workflow: nil,
          depends_on: nil,
          admission_error: nil,
          folder: folder,
          # Schema requires a non-null string; the workflow never resolved, so
          # there's no real state file — point at the folder as a best-effort,
          # non-misleading placeholder for this un-actionable error row.
          state_file: folder,
          worktree_path: nil,
          pr_url: nil,
          task: nil,
          marker_name: marker.name,
          marker_attrs: marker.attrs,
          task_history_invalid: false,
          icon: icon,
          state_label: state_label,
          mtime: folder_mtime,
          folder_mtime: folder_mtime,
          age: humanise_age(folder_mtime, now: now),
          claude_pid: nil,
          claude_pid_alive: nil,
          live_task_lock: false,
          attempt_id: nil,
          task_generation: nil,
          projection: Hive::TaskProjection.project(records: []),
          projection_data: Hive::TaskProjection.project(records: []).to_h,
          condition_gate: nil,
          condition_migration: nil,
          condition_warning: nil,
          plan_review: nil,
          patrol_fix: nil
        }
      end

      # An invalid (un-loadable) row has no Task to feed Hive::TaskAction.for and
      # its action is unambiguously error — stamp a fixed Error annotation.
      def invalid_action_annotation(row)
        row.merge(
          action_key: Hive::Schemas::TaskActionKind::ERROR,
          action_label: "Error",
          suggested_command: nil,
          next_action: nil,
          diagnostic: nil,
          plan_review: nil
        )
      end

      def annotate_actions(rows, project, project_count, config: nil, with_diagnostic: true)
        slug_counts = rows.each_with_object(Hash.new(0)) { |row, counts| counts[row[:slug]] += 1 }
        grace_sec = agent_marker_grace_sec_from_config
        rows.map do |row|
          next invalid_action_annotation(row) if row[:invalid]

          action = Hive::TaskAction.for(
            row[:task],
            marker_from_row(row),
            projection: row[:projection],
            config: config,
            project_name: project["name"],
            project_count: project_count,
            stage_collision: slug_counts[row[:slug]] > 1,
            pid_alive: row[:claude_pid_alive],
            state_file_mtime: row[:mtime],
            agent_marker_grace_sec: grace_sec,
            live_task_lock: row[:live_task_lock]
          )
          annotation = row.merge(
            action_key: action.key,
            action_label: action.label,
            suggested_command: action.command,
            outcomes: action.allowed_outcomes,
            next_action: action.next_action,
            diagnostic: with_diagnostic ? (attempt_diagnostic_for(row) || action.diagnostic) : nil,
            condition_gate: action.condition_gate&.to_h,
            condition_migration: action.migration_selection.to_h,
            condition_warning: action.condition_warning,
            plan_review: action.plan_review,
            patrol_fix: action.patrol_fix,
            state_label: condition_state_label(row, action)
          )
          task_history_invalid_annotation(annotation) || annotation
        end
      end

      def task_history_invalid_annotation(row)
        return nil unless Hive::TaskProjection.history_invalid_row?(row)

        marker = marker_from_row(row)
        row.merge(
          action_key: Hive::Schemas::TaskActionKind::ERROR,
          action_label: "Task journal invalid",
          suggested_command: nil,
          outcomes: [],
          next_action: nil,
          diagnostic: {
            "summary" => "Task history is unreadable",
            "detail" => row.dig(:marker_attrs, "message").to_s[0, 4_000],
            "source" => "marker",
            "source_path" => nil,
            "artifact_paths" => [],
            "generated_by" => "local",
            "marker_signature" => Hive::TaskClosure.marker_generation(marker),
            "suggested_next_action" => nil,
            "updated_at" => Time.now.utc.iso8601
          }
        )
      end

      def attempt_diagnostic_for(row)
        return nil unless row[:workflow].to_s == Hive::PatrolFix::WORKFLOW_ID.to_s

        identity = row[:projection_data].is_a?(Hash) ? row[:projection_data]["identity"] : nil
        attempt_id = identity.is_a?(Hash) ? identity["attempt_id"].to_s : ""
        return nil if attempt_id.empty? || attempt_id == Hive::TaskJournal::LEGACY_ATTEMPT_ID

        binding = status_attempt_store.fetch_terminal_diagnostic_binding(attempt_id)
        return nil unless binding.is_a?(Hash) && binding["attempt_id"] == attempt_id

        bound = Hive::PatrolFix::AttemptDiagnostic.read_bound(
          store: status_attempt_store, binding: binding
        )
        return nil unless bound

        diagnostic_projection(bound.fetch("document"), bound.fetch("reference"))
      end

      def diagnostic_projection(document, reference)
        paths = [ reference["path"], document.dig("log_reference", "path") ].compact.uniq
        {
          "summary" => "#{document.fetch('code')} (#{document.fetch('owner')})".byteslice(0, 120),
          "detail" => document["detail"] || "No provider-safe detail was emitted.",
          "source" => "artifact",
          "source_path" => reference.fetch("path"),
          "artifact_paths" => paths,
          "generated_by" => "local",
          "marker_signature" => Digest::SHA256.hexdigest(JSON.generate(reference)),
          "suggested_next_action" => nil,
          "updated_at" => document.fetch("recorded_at"),
          "code" => document.fetch("code"),
          "owner" => document.fetch("owner"),
          "workflow" => document.fetch("workflow"),
          "stage" => document.fetch("stage"),
          "phase" => document.fetch("phase"),
          "status" => document.fetch("status"),
          "agent_reason" => document.fetch("agent_reason"),
          "exit_code" => document.fetch("exit_code"),
          "timed_out" => document.fetch("timed_out"),
          "cancelled" => document.fetch("cancelled"),
          "signal" => document.fetch("signal"),
          "provider" => document.fetch("provider"),
          "attempt_id" => document.fetch("attempt_id"),
          "correlation_id" => document.fetch("correlation_id"),
          "task_generation" => document.fetch("task_generation"),
          "diagnostic_digest" => reference.fetch("sha256"),
          "diagnostic_reference" => reference,
          "log_reference" => document.fetch("log_reference"),
          "report_status" => document.fetch("report_status"),
          "report_parser" => document.fetch("report_parser"),
          "firewall_status" => document.fetch("firewall_status"),
          "firewall_restoration" => document.fetch("firewall_restoration"),
          "custody_status" => document.fetch("custody_status"),
          "transport_status" => document.fetch("transport_status"),
          "redaction_status" => document.fetch("redaction_status"),
          "secret_policy_version" => document.fetch("secret_policy_version")
        }
      end

      # Dependency admission reports invalid project configuration on each
      # affected row. Keep those rows visible instead of letting TaskAction's
      # condition-mode lookup degrade the whole project; nil safely selects
      # marker authority until the configuration is repaired.
      def task_action_config(project_root)
        Hive::Config.load(project_root)
      rescue Hive::UnsupportedProjectConfigError
        raise
      rescue Hive::ConfigError
        nil
      end

      def condition_state_label(row, action)
        return "#{row[:state_label]} [#{action.condition_warning}]" if action.condition_warning
        return row[:state_label] unless action.migration_selection.effective == "conditions"

        diagnostic = action.condition_gate&.diagnostics&.first
        return row[:state_label] unless diagnostic

        "#{diagnostic['condition']}=#{diagnostic['state']}"
      end

      # Memoize per status call. The daemon's StaleAgentHealer reads the
      # same key from the same global config so both surfaces classify
      # rows with one threshold; if this fetch raises a recognised
      # config error (corrupted YAML, missing file, non-Integer value),
      # warn loudly and fall back to the TaskAction constant so the
      # status snapshot never crashes over a config edge case.
      # Unexpected errors (programmer bugs, runtime NoMethodError) are
      # NOT caught here — the broader CLI rescue at bin/hive surfaces
      # those with a stack trace, which is the right behaviour.
      def agent_marker_grace_sec_from_config
        @agent_marker_grace_sec_from_config ||= begin
          daemon_cfg = Hive::Config.load_global_daemon
          Integer(daemon_cfg.fetch("agent_marker_grace_sec",
                                   Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC))
        rescue Hive::ConfigError, TypeError, ArgumentError => e
          warn "hive: invalid daemon.agent_marker_grace_sec (#{e.class}: #{e.message}); " \
               "using default #{Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC}s"
          Hive::TaskAction::DEFAULT_AGENT_MARKER_GRACE_SEC
        end
      end

      def marker_from_row(row)
        Hive::Markers::State.new(name: row[:marker_name], attrs: row[:marker_attrs], raw: nil)
      end

      def action_labels(rows)
        labels = rows.map { |row| row[:action_label] }.uniq
        labels.sort_by { |label| ACTION_LABEL_ORDER.index(label) || ACTION_LABEL_ORDER.length }
      end

      def label_for(marker)
        return Hive::AgentLimit.held_label(marker.attrs) if Hive::AgentLimit.held?(marker.name, marker.attrs)

        attrs = Hive::Markers.display_attrs(marker.attrs)
                            .map { |k, v| "#{k}=#{status_attr_value(v)}" }.join(" ")
        attrs.empty? ? marker.name.to_s : "#{marker.name} #{attrs}"
      end

      def status_attr_value(value)
        value.to_s.gsub(/\s+/, " ").strip
      end

      def pid_alive?(pid)
        Hive::ProcessKill.pid_alive?(pid)
      end

      def task_lock_holder(task)
        Hive::Lock.read_task_lock(task.folder)
      rescue StandardError => e
        warn "hive: status: failed to read task lease for #{task.folder}: #{e.class}: #{e.message}"
        nil
      end

      def live_task_lock_holder(holder)
        return nil unless holder.is_a?(Hash)

        pid = holder["pid"]
        return nil unless Hive::PidFile.identity_alive?(
          pid, recorded_start_time: holder["process_start_time"]
        )

        holder
      rescue StandardError => e
        warn "hive: status: failed to check liveness for lock pid=#{holder['pid'].inspect}: #{e.class}: #{e.message}"
        nil
      end

      def claude_pid_from_lock(holder)
        holder.is_a?(Hash) ? holder["claude_pid"] : nil
      end

      def humanise_age(mtime, now: Time.now)
        seconds = [ (now - mtime).to_i, 0 ].max
        if seconds < 60
          "#{seconds}s ago"
        elsif seconds < 3600
          "#{seconds / 60}m ago"
        elsif seconds < 86_400
          "#{seconds / 3600}h ago"
        else
          "#{seconds / 86_400}d ago"
        end
      end

      # Map a Hive::Error subclass to a StatusErrorKind value. Status's
      # producer surface is much narrower than Run's — only ConfigError /
      # InternalError surface deliberately; everything else is the generic
      # `error` fallback (matching the convention used by approve/findings/
      # markers/stage_action/finding_toggle).
      #
      # The `--diagnose` route has a wider producer surface (TaskResolver
      # AmbiguousSlug/InvalidTaskPath, DiagnosisAgent StaleMarker/
      # DiagnosisInFlight) — those map through StatusDiagnoseErrorKind so
      # agent callers can branch on retry-vs-escalate without parsing
      # error messages. Non-diagnose callers stay on the narrow
      # StatusErrorKind enum.
      def error_kind_for(error)
        if @diagnose
          diagnose_error_kind_for(error)
        else
          case error
          when Hive::ConfigError   then Hive::Schemas::StatusErrorKind::CONFIG
          when Hive::InternalError then Hive::Schemas::StatusErrorKind::INTERNAL
          else                          Hive::Schemas::StatusErrorKind::ERROR
          end
        end
      end

      def diagnose_error_kind_for(error)
        require "hive/diagnosis_agent"
        case error
        when Hive::DiagnosisAgent::StaleMarker
          Hive::Schemas::StatusDiagnoseErrorKind::STALE_MARKER
        when Hive::DiagnosisAgent::DiagnosisInFlight
          Hive::Schemas::StatusDiagnoseErrorKind::IN_FLIGHT
        when Hive::AmbiguousSlug
          Hive::Schemas::StatusDiagnoseErrorKind::AMBIGUOUS_SLUG
        when Hive::InvalidTaskPath
          Hive::Schemas::StatusDiagnoseErrorKind::SLUG_NOT_FOUND
        when Hive::ConfigError
          Hive::Schemas::StatusDiagnoseErrorKind::CONFIG
        when Hive::InternalError
          Hive::Schemas::StatusDiagnoseErrorKind::INTERNAL
        else
          Hive::Schemas::StatusDiagnoseErrorKind::ERROR
        end
      end
    end
  end
end
