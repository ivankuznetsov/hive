require "json"
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
require "hive/task_projection/store"
require "hive/task_resolver"
require "hive/brainstorm_parser"
require "hive/gh"
require "hive/pr"
require "hive/tui/views/hyperlink"

module Hive
  module Commands
    class Status
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

      def initialize(json: false, diagnose: nil, project: nil, stage: nil, write: false, force: false, archive: false)
        @json = json
        @diagnose = diagnose
        @project = project
        @stage = stage
        @write = write
        @force = force
        @archive = archive
      end

      def call
        @stdout_written = false
        if @diagnose && @diagnose.to_s.strip.empty?
          raise Hive::Error, "--diagnose requires a non-empty task slug"
        end
        if @write && @diagnose.nil?
          raise Hive::Error, "--write requires --diagnose <task>"
        end
        return diagnose_call if @diagnose

        do_call
      rescue Hive::Error => e
        emit_error_envelope(e, schema: status_schema_for_call) if @json && !@stdout_written
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped, schema: status_schema_for_call) if @json && !@stdout_written
        raise wrapped
      end

      # `--diagnose` routes through diagnose_call which emits the
      # `hive-status-diagnose` envelope on success; the top-level rescue
      # must match the same schema so consumers can validate either
      # branch against `urn:hive:schema:status-diagnose:v1`. Plain
      # `hive status --json` stays on `hive-status`.
      def status_schema_for_call
        @diagnose ? "hive-status-diagnose" : "hive-status"
      end

      def do_call
        projects = Hive::Config.registered_projects
        if @json
          puts JSON.generate(json_payload(projects))
          @stdout_written = true
          return
        end

        if projects.empty?
          puts "(no projects registered; run `hive init <path>`)"
          return
        end

        admission_context = build_admission_context(projects)
        projects.each do |project|
          render_project(project, project_count: projects.size, admission_context: admission_context)
        rescue StandardError => e
          # Symmetry with the JSON path's project_payload_or_degraded: isolate
          # per-project failures so one project (e.g. a malformed workflow
          # descriptor or config) doesn't blank text `status` for every other
          # project. Degrade to a one-line breadcrumb and keep rendering the rest.
          warn "hive: status: project #{project['name'].inspect} failed to render " \
               "(#{e.class}: #{e.message}); skipping it so other projects still display"
          puts "#{project['name']}: failed to load (#{e.message})"
        end
      end

      # Stable schema for agent / wrapper consumption. Adding new keys is
      # non-breaking; removing or renaming keys must bump a documented
      # version. `tasks[].marker` is the lowercased symbol name as a string;
      # `tasks[].attrs` is the marker's attribute map.
      def json_payload(projects, stages: nil, exclude_archived: false, admission_context: nil)
        admission_context ||= build_admission_context(
          projects, exclude_archived: exclude_archived
        )
        {
          "schema" => "hive-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
          "ok" => true,
          "generated_at" => Time.now.utc.iso8601,
          "projects" => projects.map do |p|
            project_payload_or_degraded(
              p,
              project_count: projects.size,
              stages: stages,
              exclude_archived: exclude_archived,
              admission_context: admission_context
            )
          end
        }
      end

      # Isolate per-project failures. A single project with a malformed
      # config.yml (e.g. an invalid `dependency_gate_stage`) used to raise
      # out of `project_payload` and abort the entire `hive status --json`;
      # the daemon's StatusConsumer then reads `ok:false` and skips the
      # whole tick, freezing auto-advance fleet-wide. Degrade the offending
      # project to an empty task list (with a stderr breadcrumb in
      # daemon.log) so the rest of the fleet keeps advancing. The fallback
      # entry still validates against the published hive-status schema.
      def project_payload_or_degraded(project, project_count:, stages: nil, exclude_archived: false,
                                      admission_context: nil)
        project_payload(
          project,
          project_count: project_count,
          stages: stages,
          exclude_archived: exclude_archived,
          admission_context: admission_context
        )
      rescue StandardError => e
        warn "hive: status: project #{project['name'].inspect} payload failed " \
             "(#{e.class}: #{e.message}); reporting it with no tasks so other projects still advance"
        {
          "name" => project["name"],
          "path" => project["path"],
          "hive_state_path" => project["hive_state_path"],
          "tasks" => [],
          "legacy_stage_dirs" => [],
          "legacy_migrate_command" => nil
        }
      end

      def project_payload(project, project_count:, stages: nil, exclude_archived: false,
                          admission_context: nil)
        path = project["path"]
        hive_state = project["hive_state_path"]
        base = {
          "name" => project["name"],
          "path" => path,
          "hive_state_path" => hive_state
        }
        if !File.directory?(path)
          base.merge("error" => "missing_project_path", "tasks" => [])
        elsif !File.directory?(hive_state)
          base.merge("error" => "not_initialised", "tasks" => [])
        else
          # Hold the project overlay stable across load! + resolve: StatusFeed
          # runs this on both the poller thread and per-request threads, so a
          # concurrent load!(other project) must not clear THIS project's
          # overlay mid-resolve (which would make its custom-workflow rows
          # raise UnknownWorkflow and degrade the whole project). See
          # Hive::Workflows::Project::LOCK.
          Hive::Workflows::Project.synchronize do
            Hive::Workflows::Project.load!(path)
            # JSON path: pay the diagnostic-extraction cost because
            # external consumers (TUI, daemon, bots) read `diagnostic` off
            # every row. Schema mandates the field.
            config = task_action_config(path)
            rows = annotate_actions(
              collect_rows(hive_state, stages: stages, exclude_archived: exclude_archived),
              project, project_count, config: config, with_diagnostic: true
            )
            rows = annotate_dependencies(
              rows, project, admission_context: admission_context
            )
            rows = archive_rows(rows) if @archive
            out = base.merge("tasks" => rows.map { |r| task_payload(r) })
            # Always emit `legacy_stage_dirs` (default empty array) so
            # consumers can branch on `.empty?` without a `key?` probe and
            # the schema's optional-but-never-undefined contract holds.
            legacy_stage_dirs = detect_legacy_stage_dirs(hive_state)
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

      def detect_legacy_stage_dirs(hive_state)
        stages_root = File.join(hive_state, "stages")
        return [] unless File.directory?(stages_root)

        Dir.children(stages_root).filter_map do |basename|
          next if Hive::Workflows.all_stage_dirs.include?(basename)
          next if STATUS_PRIVATE_STAGE_DIRS.include?(basename)

          dir = File.join(stages_root, basename)
          next unless File.directory?(dir)

          task_count = Dir.children(dir).count do |child|
            Hive::Stages.task_slug?(child) && File.directory?(File.join(dir, child))
          end
          next if task_count.zero?

          { "stage_dir" => basename, "task_count" => task_count }
        end.sort_by { |entry| entry["stage_dir"] }
      end

      def task_payload(row)
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
          "mtime" => row[:mtime].utc.iso8601(6),
          "folder_mtime" => row[:folder_mtime].utc.iso8601(6),
          "age_seconds" => (Time.now - row[:mtime]).to_i,
          "claude_pid" => row[:claude_pid],
          "claude_pid_alive" => row[:claude_pid_alive],
          # Coerced to boolean so nil never leaks into JSON: live_task_lock is
          # a tri-state internally (nil = no .lock, true/false = liveness),
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
          "condition_gate" => row[:condition_gate],
          "condition_migration" => row[:condition_migration],
          "condition_provenance" => row.dig(:projection_data, "provenance") || {},
          "shadow_audit" => row.dig(:projection_data, "shadow_audit") || {},
          "condition_warning" => row[:condition_warning],
          # Count of still-unanswered brainstorm Q&A questions (issue #270).
          # 0 for every non-brainstorm / non-needs_input row. Lets an agent
          # or operator tell "the daemon is holding this brainstorm because
          # N answers are outstanding" apart from "genuinely waiting for a
          # first answer" or "broken" — the daemon's answers-pending gate
          # is otherwise only visible in daemon.log. Additive field per the
          # SCHEMA_VERSIONS policy in lib/hive.rb — no version bump (mirrors
          # `live_task_lock`).
          "unanswered_questions" => unanswered_question_count(row),
          "action" => row[:action_key],
          "action_label" => row[:action_label],
          "suggested_command" => row[:suggested_command],
          "next_action" => row[:next_action],
          "diagnostic" => row[:diagnostic]
        }
        payload["workflow"] = row[:workflow].to_s if row.key?(:workflow) && !row[:workflow].nil?
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
      # AGENT_WORKING the same way `hive status --json` and the TUI do.
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

      def render_project(project, project_count:, admission_context: nil)
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

        Hive::Workflows::Project.load!(path)
        # Text-mode renders icon / state_label / suggested_command / age
        # only — `diagnostic` is unused here, so skip the bounded file-
        # I/O that TaskAction#diagnostic performs per red row. JSON path
        # still pays the full cost via project_payload.
        rows = annotate_actions(
          collect_rows(hive_state), project, project_count,
          config: task_action_config(path), with_diagnostic: false
        )
        rows = annotate_dependencies(rows, project, admission_context: admission_context)
        if @archive
          render_archive_project(project, rows)
          return
        end

        hidden_rows, visible_rows = rows.partition { |row| hide_archived_row?(row) }
        legacy = detect_legacy_stage_dirs(hive_state)
        puts project["name"]
        render_legacy_stage_warning(legacy) unless legacy.empty?
        if visible_rows.empty? && hidden_rows.empty?
          puts "  no active tasks" if legacy.empty?
          return
        end

        action_labels(visible_rows).each do |label|
          stage_rows = visible_rows.select { |r| r[:action_label] == label }
          next if stage_rows.empty?

          puts "  #{label}"
          stage_rows.sort_by { |r| -r[:mtime].to_i }.each do |r|
            command = r[:suggested_command] || "-"
            state = [ r[:state_label], dependency_indicator(r) ].compact.join(" ")
            puts "    #{r[:icon]} #{display_identity_with_pr(r, TEXT_IDENTITY_WIDTH)} " \
                 "#{state.ljust(24)} #{command} #{r[:age]}"
          end
        end
        render_archived_hidden_summary(hidden_rows.size) unless hidden_rows.empty?
      end

      def hide_archived_row?(row)
        Hive::ArchiveFilter.hide?(
          stage: row[:stage],
          mtime: row[:mtime],
          folder_mtime: row[:folder_mtime]
        )
      end

      def render_archive_project(project, rows)
        rows = archive_rows(rows)
        puts project["name"]
        if rows.empty?
          puts "  no archived tasks"
          return
        end

        puts "  Archived"
        rows.sort_by { |row| -row[:mtime].to_i }.each do |row|
          command = row[:suggested_command] || "-"
          state = [ row[:state_label], dependency_indicator(row) ].compact.join(" ")
          puts "    #{row[:icon]} #{display_identity_with_pr(row, TEXT_IDENTITY_WIDTH)} " \
               "#{state.ljust(24)} #{command} #{row[:age]}"
        end
      end

      def archive_rows(rows)
        rows.select { |row| Hive::ArchiveFilter.archived?(row[:stage]) }
      end

      def render_archived_hidden_summary(hidden_count)
        puts "  … and #{hidden_count} archived >3d ago (hive archive to view)"
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
      # overlay. `exclude_archived: true` subtracts only the terminal
      # archive dir from that per-project union.
      def default_stage_dirs(exclude_archived)
        dirs = Hive::Workflows.all_stage_dirs
        exclude_archived ? dirs - [ Hive::ArchiveFilter::ARCHIVE_STAGE_DIR ] : dirs
      end

      def collect_rows(hive_state, stages: nil, exclude_archived: false)
        rows = []
        Array(stages || default_stage_dirs(exclude_archived)).each do |stage|
          stage_dir = File.join(hive_state, "stages", stage)
          next unless File.directory?(stage_dir)

          stage_task_entries(stage_dir).each do |entry|
            next unless File.directory?(entry)

            slug = File.basename(entry)
            begin
              begin
                task = Hive::Task.new(entry)
              rescue Hive::InvalidTaskPath => e
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
                rows << invalid_task_row(stage: stage, slug: slug, folder: entry, message: e.message)
                next
              end
              marker = Hive::Markers.current(task.state_file)
              projection = Hive::TaskProjection::Store.new(task_folder: task.folder).read(marker: marker)
              folder_mtime = File.mtime(entry)
              mtime = File.exist?(task.state_file) ? File.mtime(task.state_file) : folder_mtime
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
                projection: projection,
                projection_data: projection.to_h,
                icon: icon,
                state_label: state_label,
                mtime: mtime,
                folder_mtime: folder_mtime,
                age: humanise_age(mtime),
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
            # (markers.rb:59-61), or the .lock read in task_lock_holder — all of
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

      def annotate_dependencies(rows, project, admission_context: nil)
        context = admission_context || build_admission_context([ project ])
        rows.each { |row| apply_dependency_verdict(row, context, project) }
        rows
      end

      def build_admission_context(projects, exclude_archived: false)
        Hive::DependencySnapshot.admission_context(
          projects, exclude_archived: exclude_archived
        )
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

      def apply_dependency_verdict(row, context, project)
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
        return nil unless Hive::Workflows.coding_id?(task.workflow.id) # coding-scoped: PR metadata exists only in the coding workflow
        return nil if task.stage_index < OPEN_PR_STAGE_INDEX

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
        # the inconsistency is visible (mirrors task_lock_holder's .lock
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
          # is recorded in the per-task .lock file by Hive::Agent.
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

      ACTION_LABEL_ORDER = [
        "Admission error",
        "Ready to brainstorm",
        # Generic-workflow actions (non-coding descriptors). Sorted high with
        # the other actionable "ready"/"needs" rows so generic status rows
        # don't fall to the bottom (below "Error") as unknown labels would.
        "Ready to run",
        "Ready to advance",
        # Per-stage "needs input" labels (the differentiated NEEDS_INPUT rows
        # plus the shared generic "Needs your input"). Deliberately ordered
        # between "Ready to advance" and "Ready to plan" so these actionable
        # rows sort high alongside the other "ready"/"needs" rows.
        "Answer questions",
        "Review plan draft",
        "Needs your input",
        "Needs review decision",
        "Confirm finalize",
        "Ready to plan",
        "Ready to develop",
        "Needs recovery",
        "Agent running",
        "Ready to open PR",
        "Ready for review",
        "Ready to collect artifacts",
        # Clean ad-hoc PR review parked at 6-review (REVIEW_PARKED): complete and
        # non-advancing, so it sorts with the other review-complete rows rather
        # than falling below "Error" as an unknown label.
        "Ad-hoc review complete (parked)",
        "Ready to finalize",
        "Ready to archive",
        "Archived",
        "Manually steered",
        "Error"
      ].freeze

      # Synthetic Error row for a task folder that exists but won't load — e.g.
      # a typo'd `meta.yml workflow:` / project `default_workflow:` that resolves
      # to no registered descriptor. It carries no real Task object (`task: nil`,
      # `invalid: true`); annotate_actions stamps a fixed Error annotation and
      # annotate_dependencies treats it as unblocked, so the broken task shows
      # in the snapshot instead of being silently dropped. The load error lands
      # in `marker_attrs[:message]` (surfaced in the JSON row's `attrs`).
      def invalid_task_row(stage:, slug:, folder:, message:)
        folder_mtime =
          begin
            File.mtime(folder)
          rescue SystemCallError
            Time.now
          end
        marker = Hive::Markers::State.new(
          name: :error,
          attrs: { "reason" => "invalid_task", "message" => message.to_s[0, 200] },
          raw: nil
        )
        icon, state_label = decorate(nil, marker)
        {
          invalid: true,
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
          icon: icon,
          state_label: state_label,
          mtime: folder_mtime,
          folder_mtime: folder_mtime,
          age: humanise_age(folder_mtime),
          claude_pid: nil,
          claude_pid_alive: nil,
          live_task_lock: false,
          attempt_id: nil,
          task_generation: nil,
          projection: Hive::TaskProjection.project(records: []),
          projection_data: Hive::TaskProjection.project(records: []).to_h,
          condition_gate: nil,
          condition_migration: nil,
          condition_warning: nil
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
          diagnostic: nil
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
          row.merge(
            action_key: action.key,
            action_label: action.label,
            suggested_command: action.command,
            next_action: action.next_action,
            diagnostic: with_diagnostic ? action.diagnostic : nil,
            condition_gate: action.condition_gate&.to_h,
            condition_migration: action.migration_selection.to_h,
            condition_warning: action.condition_warning,
            state_label: condition_state_label(row, action)
          )
        end
      end

      # Dependency admission reports invalid project configuration on each
      # affected row. Keep those rows visible instead of letting TaskAction's
      # condition-mode lookup degrade the whole project; nil safely selects
      # marker authority until the configuration is repaired.
      def task_action_config(project_root)
        Hive::Config.load(project_root)
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
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def task_lock_holder(task)
        lock_file = File.join(task.folder, ".lock")
        return nil unless File.exist?(lock_file)

        data = YAML.safe_load(File.read(lock_file), permitted_classes: [ Time ]) || {}
        data.is_a?(Hash) ? data : nil
      rescue StandardError => e
        # A corrupt or unparseable .lock used to silently drop us into the
        # "no lock" branch; ops would then see a row classified as ready
        # despite the disk state showing something was running. Emit a
        # warn so the inconsistency is visible without changing classifier
        # semantics (still returning nil).
        warn "hive: status: failed to read .lock at #{File.join(task.folder, '.lock')}: #{e.class}: #{e.message}"
        nil
      end

      def live_task_lock_holder(holder)
        return nil unless holder.is_a?(Hash)

        pid = holder["pid"]
        return nil unless pid.is_a?(Integer) && pid_alive?(pid)

        recorded = holder["process_start_time"]
        live = Hive::Lock.process_start_time(pid)
        # PID-reuse defense: when the lock recorded a start time and the
        # live counterpart differs (or cannot be read at all), assume the
        # original process is gone and the PID may have been recycled.
        # We deliberately lose liveness signal in environments where both
        # /proc and `ps -o lstart=` are unreadable (e.g. heavily-sandboxed
        # containers) — see `Hive::Lock.process_start_time` (lib/hive/lock.rb:128-134)
        # for the nil-return contract. A phantom-live row masking a
        # recycled PID is the worse failure mode than under-reporting
        # liveness, so we err toward "stale". Regression coverage:
        # `test_live_task_lock_with_recorded_but_unreadable_live_start_time_is_stale`
        # and `test_live_task_lock_with_mismatched_process_start_time_is_treated_as_stale`.
        return nil if recorded && live != recorded

        holder
      rescue StandardError => e
        warn "hive: status: failed to check liveness for lock pid=#{holder['pid'].inspect}: #{e.class}: #{e.message}"
        nil
      end

      def claude_pid_from_lock(holder)
        holder.is_a?(Hash) ? holder["claude_pid"] : nil
      end

      def humanise_age(mtime)
        seconds = (Time.now - mtime).to_i
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

      # Emit an ErrorPayload to stdout. Gated on @json + @stdout_written
      # so a successful payload write doesn't get double-emitted by the
      # rescue. `schema:` selects between "hive-status" (plain status)
      # and "hive-status-diagnose" (the --diagnose route) so consumers
      # see one envelope shape per CLI invocation.
      def emit_error_envelope(error, schema: "hive-status")
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: schema,
          error: error,
          error_kind: error_kind_for(error)
        )
        puts JSON.generate(payload)
        @stdout_written = true
      rescue Errno::EPIPE, JSON::GeneratorError
        # See lib/hive/commands/run.rb#emit_error_envelope for the rationale:
        # swallow emit-time failures so the original Hive::Error still
        # propagates with its documented exit_code instead of becoming
        # exit 1 via bin/hive's outermost rescue.
        @stdout_written = true
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
