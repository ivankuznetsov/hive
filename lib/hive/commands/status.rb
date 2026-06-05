require "json"
require "time"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/stages"
require "hive/archive_filter"
require "hive/task_action"
require "hive/task_resolver"
require "hive/brainstorm_parser"

module Hive
  module Commands
    class Status
      # Stage dir whose `needs_input` rows carry a brainstorm Q&A file we
      # count unanswered questions from (issue #270).
      BRAINSTORM_STAGE_DIR = "2-brainstorm".freeze

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

        projects.each do |project|
          render_project(project, project_count: projects.size)
        end
      end

      # Stable schema for agent / wrapper consumption. Adding new keys is
      # non-breaking; removing or renaming keys must bump a documented
      # version. `tasks[].marker` is the lowercased symbol name as a string;
      # `tasks[].attrs` is the marker's attribute map.
      def json_payload(projects)
        {
          "schema" => "hive-status",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status"),
          "ok" => true,
          "generated_at" => Time.now.utc.iso8601,
          "projects" => projects.map { |p| project_payload(p, project_count: projects.size) }
        }
      end

      def project_payload(project, project_count:)
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
          # JSON path: pay the diagnostic-extraction cost because
          # external consumers (TUI, daemon, bots) read `diagnostic` off
          # every row. Schema mandates the field.
          rows = annotate_actions(collect_rows(hive_state), project, project_count, with_diagnostic: true)
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

      # Scan `<hive_state>/stages/` for directories that are NOT in
      # `Hive::Stages::DIRS` and contain at least one task-slug-shaped
      # subfolder. Returns `[{"stage_dir" => name, "task_count" => N},
      # ...]` sorted by name. `collect_rows` walks only canonical DIRS, so
      # any stage rename in `lib/hive/stages.rb` leaves pre-rename tasks
      # unreachable from every operator surface — this is the detector
      # that turns that silent gap into a visible warning instead. Only
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
          next if Hive::Stages::DIRS.include?(basename)
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
        {
          "stage" => row[:stage],
          "slug" => row[:slug],
          "id" => row[:id],
          "display_name" => row[:display_name],
          "folder" => row[:folder],
          "state_file" => row[:state_file],
          "worktree_path" => row[:worktree_path],
          "marker" => row[:marker_name].to_s,
          "attrs" => row[:marker_attrs],
          "mtime" => row[:mtime].utc.iso8601,
          "folder_mtime" => row[:folder_mtime].utc.iso8601,
          "age_seconds" => (Time.now - row[:mtime]).to_i,
          "claude_pid" => row[:claude_pid],
          "claude_pid_alive" => row[:claude_pid_alive],
          # Coerced to boolean so nil never leaks into JSON: live_task_lock is
          # a tri-state internally (nil = no .lock, true/false = liveness),
          # but external consumers only need "is the runner still holding it"
          # and would have to handle JSON null otherwise. Additive field per
          # the SCHEMA_VERSIONS policy in lib/hive.rb — no version bump.
          "live_task_lock" => row[:live_task_lock] == true,
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
        liveness = liveness_kwargs_for(task)
        action = Hive::TaskAction.for(task, marker, project_name: project_name_for(task), **liveness)
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
            emit_diagnose_result(task, diagnostic, diagnostic["source_path"])
            return
          end

          require "hive/diagnosis_agent"
          result = Hive::DiagnosisAgent.run!(task: task, local_diagnostic: diagnostic)
          diagnostic = Hive::TaskAction.for(task, marker, project_name: project_name_for(task), **liveness).diagnostic
          emit_diagnose_result(task, diagnostic, result[:path])
        else
          emit_diagnose_result(task, diagnostic, nil)
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

      def emit_diagnose_result(task, diagnostic, path)
        if @json
          puts JSON.generate(
            "schema" => "hive-status-diagnose",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status-diagnose"),
            "ok" => true,
            "slug" => task.slug,
            "id" => task.id,
            "display_name" => task.display_name,
            "task_folder" => task.folder,
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
            puts "no red-status diagnostic for #{task.slug}"
          end
        end
      end

      def project_name_for(task)
        project = Hive::Config.registered_projects.find { |entry| entry["path"] == task.project_root }
        project ? project["name"] : File.basename(task.project_root)
      end

      def render_project(project, project_count:)
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

        # Text-mode renders icon / state_label / suggested_command / age
        # only — `diagnostic` is unused here, so skip the bounded file-
        # I/O that TaskAction#diagnostic performs per red row. JSON path
        # still pays the full cost via project_payload.
        rows = annotate_actions(collect_rows(hive_state), project, project_count, with_diagnostic: false)
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
            puts "    #{r[:icon]} #{display_identity(r).ljust(42)} #{r[:state_label].ljust(24)} #{command} #{r[:age]}"
          end
        end
        render_archived_hidden_summary(hidden_rows.size) unless hidden_rows.empty?
      end

      def hide_archived_row?(row)
        Hive::ArchiveFilter.hide?(
          stage: row[:stage],
          marker_name: row[:marker_name],
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
          puts "    #{row[:icon]} #{row[:slug].ljust(36)} #{row[:state_label].ljust(24)} #{command} #{row[:age]}"
        end
      end

      def archive_rows(rows)
        rows.select { |row| Hive::ArchiveFilter.archived?(row[:stage]) }
      end

      def render_archived_hidden_summary(hidden_count)
        puts "  … and #{hidden_count} archived >3d ago (hive archive to view)"
      end

      def display_identity(row)
        id = row[:id] ? "##{row[:id]}" : "—"
        "#{id} #{row[:display_name] || row[:slug]}"
      end

      def render_legacy_stage_warning(legacy)
        total = legacy.sum { |entry| entry["task_count"] }
        dirs = legacy.map { |entry| "#{entry['stage_dir']} (#{entry['task_count']})" }.join(", ")
        puts "  ⚠ #{total} task#{total == 1 ? '' : 's'} hidden in legacy stage dirs: #{dirs}"
        puts "    run `hive migrate` to move them into the current layout"
      end

      def collect_rows(hive_state)
        rows = []
        Hive::Stages::DIRS.each do |stage|
          stage_dir = File.join(hive_state, "stages", stage)
          next unless File.directory?(stage_dir)

          Dir[File.join(stage_dir, "*")].each do |entry|
            next unless File.directory?(entry)

            slug = File.basename(entry)
            begin
              task = Hive::Task.new(entry)
            rescue Hive::InvalidTaskPath
              next
            end
            marker = Hive::Markers.current(task.state_file)
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
              folder: entry,
              state_file: task.state_file,
              worktree_path: worktree_path,
              task: task,
              marker_name: marker.name,
              marker_attrs: marker.attrs,
              icon: icon,
              state_label: state_label,
              mtime: mtime,
              folder_mtime: folder_mtime,
              age: humanise_age(mtime),
              claude_pid: claude_pid,
              claude_pid_alive: claude_pid ? pid_alive?(claude_pid.to_i) : nil,
              live_task_lock: !live_holder.nil?
            }
          end
        end
        rows
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
        "Ready to brainstorm",
        "Needs your input",
        "Ready to plan",
        "Ready to develop",
        "Needs recovery",
        "Agent running",
        "Ready to open PR",
        "Ready for review",
        "Ready to collect artifacts",
        "Ready to finalize",
        "Ready to archive",
        "Archived",
        "Manually steered",
        "Error"
      ].freeze

      def annotate_actions(rows, project, project_count, with_diagnostic: true)
        slug_counts = rows.each_with_object(Hash.new(0)) { |row, counts| counts[row[:slug]] += 1 }
        grace_sec = agent_marker_grace_sec_from_config
        rows.map do |row|
          action = Hive::TaskAction.for(
            row[:task],
            marker_from_row(row),
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
            diagnostic: with_diagnostic ? action.diagnostic : nil
          )
        end
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
