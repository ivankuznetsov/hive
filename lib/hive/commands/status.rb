require "json"
require "time"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/stages"
require "hive/task_action"
require "hive/task_resolver"

module Hive
  module Commands
    class Status
      ICON = {
        none: "·",
        waiting: "⏸",
        complete: "✓",
        agent_working: "🤖",
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

      def initialize(json: false, diagnose: nil, project: nil, stage: nil, write: false, force: false)
        @json = json
        @diagnose = diagnose
        @project = project
        @stage = stage
        @write = write
        @force = force
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
          base.merge("tasks" => rows.map { |r| task_payload(r) })
        end
      end

      def task_payload(row)
        {
          "stage" => row[:stage],
          "slug" => row[:slug],
          "folder" => row[:folder],
          "state_file" => row[:state_file],
          "worktree_path" => row[:worktree_path],
          "marker" => row[:marker_name].to_s,
          "attrs" => row[:marker_attrs],
          "mtime" => row[:mtime].utc.iso8601,
          "age_seconds" => (Time.now - row[:mtime]).to_i,
          "claude_pid" => row[:claude_pid],
          "claude_pid_alive" => row[:claude_pid_alive],
          "action" => row[:action_key],
          "action_label" => row[:action_label],
          "suggested_command" => row[:suggested_command],
          "next_action" => row[:next_action],
          "diagnostic" => row[:diagnostic]
        }
      end

      def diagnose_call
        task = Hive::TaskResolver.new(
          @diagnose,
          project_filter: @project,
          stage_filter: @stage
        ).resolve
        marker = Hive::Markers.current(task.state_file)
        action = Hive::TaskAction.for(task, marker, project_name: project_name_for(task))
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
          diagnostic = Hive::TaskAction.for(task, marker, project_name: project_name_for(task)).diagnostic
          emit_diagnose_result(task, diagnostic, result[:path])
        else
          emit_diagnose_result(task, diagnostic, nil)
        end
      end

      def emit_diagnose_result(task, diagnostic, path)
        if @json
          puts JSON.generate(
            "schema" => "hive-status-diagnose",
            "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-status-diagnose"),
            "ok" => true,
            "slug" => task.slug,
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
        puts project["name"]
        if rows.empty?
          puts "  no active tasks"
          return
        end

        action_labels(rows).each do |label|
          stage_rows = rows.select { |r| r[:action_label] == label }
          next if stage_rows.empty?

          puts "  #{label}"
          stage_rows.sort_by { |r| -r[:mtime].to_i }.each do |r|
            command = r[:suggested_command] || "-"
            puts "    #{r[:icon]} #{r[:slug].ljust(36)} #{r[:state_label].ljust(24)} #{command} #{r[:age]}"
          end
        end
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
            mtime = File.exist?(task.state_file) ? File.mtime(task.state_file) : File.mtime(entry)
            icon, state_label = decorate(task, marker)
            claude_pid = lookup_claude_pid(task)
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
              folder: entry,
              state_file: task.state_file,
              worktree_path: worktree_path,
              task: task,
              marker_name: marker.name,
              marker_attrs: marker.attrs,
              icon: icon,
              state_label: state_label,
              mtime: mtime,
              age: humanise_age(mtime),
              claude_pid: claude_pid,
              claude_pid_alive: claude_pid ? pid_alive?(claude_pid.to_i) : nil
            }
          end
        end
        rows
      end

      def decorate(task, marker)
        if marker.name == :agent_working
          # Marker only carries the hive runner PID; the claude subprocess PID
          # is recorded in the per-task .lock file by Hive::Agent.
          pid = lookup_claude_pid(task) || marker.attrs["pid"]
          if pid && pid_alive?(pid.to_i)
            [ "🤖", "agent_working pid=#{pid}" ]
          else
            [ "⚠", "stale lock pid=#{pid}" ]
          end
        else
          [ ICON.fetch(marker.name, "·"), label_for(marker) ]
        end
      end

      ACTION_LABEL_ORDER = [
        "Ready to brainstorm",
        "Needs your input",
        "Ready to plan",
        "Ready to develop",
        "Review findings",
        "Needs recovery",
        "Ready to open PR",
        "Ready for review",
        "Ready to finalize",
        "Ready to archive",
        "Archived",
        "Error"
      ].freeze

      def annotate_actions(rows, project, project_count, with_diagnostic: true)
        slug_counts = rows.each_with_object(Hash.new(0)) { |row, counts| counts[row[:slug]] += 1 }
        rows.map do |row|
          action = Hive::TaskAction.for(
            row[:task],
            marker_from_row(row),
            project_name: project["name"],
            project_count: project_count,
            stage_collision: slug_counts[row[:slug]] > 1
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

      def marker_from_row(row)
        Hive::Markers::State.new(name: row[:marker_name], attrs: row[:marker_attrs], raw: nil)
      end

      def action_labels(rows)
        labels = rows.map { |row| row[:action_label] }.uniq
        labels.sort_by { |label| ACTION_LABEL_ORDER.index(label) || ACTION_LABEL_ORDER.length }
      end

      def label_for(marker)
        attrs = marker.attrs.map { |k, v| "#{k}=#{v}" }.join(" ")
        attrs.empty? ? marker.name.to_s : "#{marker.name} #{attrs}"
      end

      def pid_alive?(pid)
        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      end

      def lookup_claude_pid(task)
        lock_file = File.join(task.folder, ".lock")
        return nil unless File.exist?(lock_file)

        data = YAML.safe_load(File.read(lock_file)) || {}
        data.is_a?(Hash) ? data["claude_pid"] : nil
      rescue StandardError
        nil
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
