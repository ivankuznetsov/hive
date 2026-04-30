require "json"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"
require "hive/agent"
require "hive/stages"
require "hive/task_action"
require "hive/task_resolver"

module Hive
  module Commands
    class Run
      # Single source of truth for the hive-run JSON envelope's required keys.
      # `report_json` builds the payload from this list so the schema-drift
      # test (test/unit/schema_files_test.rb) and the producer share one
      # definition: adding/removing a key here is the only place to do it.
      REQUIRED_PAYLOAD_KEYS = %w[
        schema schema_version slug stage stage_index folder state_file
        marker attrs commit_action next_action
      ].freeze

      def initialize(target, project: nil, stage: nil, json: false, quiet: false)
        @target = target
        @project_filter = project
        @stage_filter = stage
        @json = json
        @quiet = quiet
      end

      def call
        @stdout_written = false
        do_call
      rescue Hive::Error => e
        emit_error_envelope(e) if @json && !@stdout_written
        raise
      rescue StandardError => e
        wrapped = Hive::InternalError.new("internal error: #{e.class}: #{e.message}")
        emit_error_envelope(wrapped) if @json && !@stdout_written
        raise wrapped
      end

      def do_call
        task = Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @stage_filter
        ).resolve
        cfg = Hive::Config.load(task.project_root)

        Hive::Lock.with_task_lock(task.folder, slug: task.slug, stage: task.stage_name) do
          runner = pick_runner(task)
          result = runner.call(task, cfg)
          commit_after(task, result)
          report(task, result)
        end
      end

      def pick_runner(task)
        case task.stage_name
        when "inbox"
          require "hive/stages/inbox"
          Hive::Stages::Inbox.method(:run!)
        when "brainstorm"
          require "hive/stages/brainstorm"
          Hive::Stages::Brainstorm.method(:run!)
        when "plan"
          require "hive/stages/plan"
          Hive::Stages::Plan.method(:run!)
        when "execute"
          require "hive/stages/execute"
          Hive::Stages::Execute.method(:run!)
        when "review"
          require "hive/stages/review"
          Hive::Stages::Review.method(:run!)
        when "pr"
          require "hive/stages/pr"
          Hive::Stages::Pr.method(:run!)
        when "done"
          require "hive/stages/done"
          Hive::Stages::Done.method(:run!)
        else
          raise StageError, "no runner for stage #{task.stage_name}"
        end
      end

      def commit_after(task, result)
        return unless result && result[:commit]

        ops = Hive::GitOps.new(task.project_root)
        Hive::Lock.with_commit_lock(task.hive_state_path) do
          ops.hive_commit(stage_name: "#{task.stage_index}-#{task.stage_name}",
                          slug: task.slug,
                          action: result[:commit])
        end
      end

      def report(task, result)
        marker = Hive::Markers.current(task.state_file)
        if @quiet
          # Quiet mode: skip stdout/stderr but preserve the dual-signal
          # raise on :error markers so composing callers (StageAction)
          # can surface them in their own envelope.
          raise Hive::TaskInErrorState, "stage recorded :error (#{marker.attrs.inspect})" if marker.name == :error
        elsif @json
          report_json(task, result, marker)
        else
          report_text(task, result, marker)
        end
      end

      # Stable schema for agent / wrapper consumption. The closed set of
      # `next_action.kind` values is exported as Hive::Schemas::NextActionKind
      # so producer and tests share a single source of truth.
      def report_json(task, result, marker)
        values = {
          "schema" => "hive-run",
          "schema_version" => Hive::Schemas::SCHEMA_VERSIONS.fetch("hive-run"),
          "slug" => task.slug,
          "stage" => task.stage_name,
          "stage_index" => task.stage_index,
          "folder" => task.folder,
          "state_file" => task.state_file,
          "marker" => marker.name.to_s,
          "attrs" => marker.attrs,
          "commit_action" => result.is_a?(Hash) ? result[:commit] : nil,
          "next_action" => json_next_action(task, marker)
        }
        # Build the emitted hash strictly in REQUIRED_PAYLOAD_KEYS order so
        # adding a key to one without the other is a load-time error rather
        # than silent schema drift.
        payload = REQUIRED_PAYLOAD_KEYS.to_h { |key| [ key, values.fetch(key) ] }
        # The JSON payload is written to stdout *before* the raise. bin/hive
        # rescues Hive::Error and calls `exit(e.exit_code)`; Ruby's normal
        # interpreter shutdown flushes stdout via IO finalizers, so the
        # caller receives the full JSON document AND a non-zero exit code
        # (3, TASK_IN_ERROR) as a dual signal.
        puts JSON.generate(payload)
        @stdout_written = true
        if [ :error, :review_error ].include?(marker.name)
          raise Hive::TaskInErrorState, "stage recorded :#{marker.name} (#{marker.attrs.inspect})"
        end
      end

      def json_next_action(task, marker)
        kind = Hive::Schemas::NextActionKind
        case marker.name
        when :waiting, :execute_waiting
          { "kind" => kind::EDIT, "target" => task.state_file, "rerun_with" => friendly_command(task, marker) }
        when *Hive::Markers::TERMINAL_MARKER_NAMES
          approve_action(task, next_stage_dir(task))
        when :execute_stale
          { "kind" => kind::RECOVER_STALE,
            "instructions" => "edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run" }
        when :review_waiting
          { "kind" => kind::EDIT,
            "target" => task.folder,
            "instructions" => "toggle [x] on findings in reviews/*-NN.md or reviews/escalations-NN.md, then re-run",
            "rerun_with" => "hive run #{task.folder}" }
        when :review_stale
          { "kind" => kind::RECOVER_STALE,
            "instructions" => "edit reviewer files / escalations.md, lower the highest-pass-N reviewer files, " \
                              "remove the REVIEW_STALE marker, then re-run",
            "markers_to_clear" => [ "review_stale" ] }
        when :review_ci_stale
          { "kind" => kind::RECOVER_STALE,
            "instructions" => "fix CI failures, edit reviews/ci-blocked.md, remove the REVIEW_CI_STALE marker, " \
                              "then re-run",
            "markers_to_clear" => [ "review_ci_stale" ] }
        when :error
          { "kind" => Hive::Schemas::NextActionKind::NO_OP, "error" => marker.attrs }
        when :review_error
          # Surface phase + reason from the marker so polling agents can
          # branch on the structured payload without parsing the marker
          # themselves. Echoes every other attr (pass, files, …) under
          # "error" so no signal is lost.
          {
            "kind" => Hive::Schemas::NextActionKind::NO_OP,
            "phase" => marker.attrs["phase"],
            "reason" => marker.attrs["reason"],
            "error" => marker.attrs,
            "instructions" => "investigate; clear the marker via " \
                              "`hive markers clear #{task.folder} --name REVIEW_ERROR`; re-run"
          }
        else
          { "kind" => Hive::Schemas::NextActionKind::NO_OP }
        end
      end

      # Emit an APPROVE action with `--from <stage>` so a retry after a
      # partial success fails with WRONG_STAGE (4) instead of advancing
      # twice. The `command` field is a copy-paste-executable shell line.
      def approve_action(task, dest_path)
        kind = Hive::Schemas::NextActionKind
        return { "kind" => kind::NO_OP, "reason" => "final_stage" } unless dest_path

        from_stage_dir = "#{task.stage_index}-#{task.stage_name}"
        {
          "kind" => kind::APPROVE,
          "slug" => task.slug,
          "from" => task.folder,
          "from_stage" => from_stage_dir,
          "to" => "#{dest_path}/",
          "to_stage" => File.basename(dest_path),
          "command" => friendly_command(task, Hive::Markers.current(task.state_file))
        }
      end

      def report_text(task, _result, marker)
        puts "hive: marker=#{marker.name}"
        puts "  state_file: #{task.state_file}"
        case marker.name
        when :waiting, :execute_waiting
          puts "  next: edit the file, then `#{friendly_command(task, marker)}` again"
        when *Hive::Markers::TERMINAL_MARKER_NAMES
          command = friendly_command(task, marker)
          puts "  next: #{command}" if command
        when :execute_stale
          puts "  next: edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run"
        when :review_waiting
          puts "  next: toggle [x] on findings in reviews/*-NN.md or reviews/escalations-NN.md, " \
               "then `hive run #{task.folder}`"
        when :review_stale
          puts "  next: edit reviewer files / escalations.md, lower the highest-pass-N reviewer files, " \
               "remove the REVIEW_STALE marker, then re-run"
        when :review_ci_stale
          puts "  next: fix CI failures, edit reviews/ci-blocked.md, remove the REVIEW_CI_STALE marker, then re-run"
        when :error, :review_error
          warn "  status: ERROR (#{marker.attrs.inspect})"
          if marker.name == :review_error
            phase = marker.attrs["phase"]
            reason = marker.attrs["reason"]
            warn "  phase: #{phase}" if phase
            warn "  reason: #{reason}" if reason
            warn "  next: investigate; clear the marker via " \
                 "`hive markers clear #{task.folder} --name REVIEW_ERROR`; re-run"
          end
          raise Hive::TaskInErrorState, "stage recorded :#{marker.name} (#{marker.attrs.inspect})"
        end
      end

      def next_stage_dir(task)
        next_name = Hive::Stages.next_dir(task.stage_index)
        return nil unless next_name

        File.join(task.hive_state_path, "stages", next_name)
      end

      def friendly_command(task, marker)
        Hive::TaskAction.for(
          task,
          marker,
          project_name: project_name_for(task),
          project_count: Hive::Config.registered_projects.size
        ).command
      end

      def project_name_for(task)
        project = Hive::Config.registered_projects.find { |p| p["path"] == task.project_root }
        project ? project["name"] : task.project_name
      end

      # Emit a hive-run ErrorPayload to stdout. Gated on @json + the
      # @stdout_written flag in #call so we don't double-emit when
      # report_json already wrote the dual-signal SuccessPayload before
      # raising TaskInErrorState (see lib/hive/commands/run.rb#report_json
      # and the contract documented at the top of report_json).
      def emit_error_envelope(error)
        extras = { "slug" => @target, "stage" => @stage_filter }.compact
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-run",
          error: error,
          error_kind: error_kind_for(error),
          extras: extras
        )
        puts JSON.generate(payload)
        @stdout_written = true
      end

      # Map a Hive::Error subclass to a RunErrorKind value. Ordering matters:
      # `case/when` uses `===` (is_a?), so subclasses MUST precede their
      # ancestors. Notably:
      #   - WrongStage precedes nothing here, but FinalStageReached < WrongStage
      #     so it correctly matches "wrong_stage" via this clause.
      #   - AmbiguousSlug precedes the implicit InvalidTaskPath fallthrough
      #     (AmbiguousSlug < InvalidTaskPath); without this ordering the
      #     more general InvalidTaskPath case (when added) would shadow it.
      def error_kind_for(error)
        case error
        when Hive::WrongStage         then Hive::Schemas::RunErrorKind::WRONG_STAGE
        when Hive::ConcurrentRunError then Hive::Schemas::RunErrorKind::CONCURRENT_RUN
        when Hive::TaskInErrorState   then Hive::Schemas::RunErrorKind::TASK_IN_ERROR
        when Hive::StageError         then Hive::Schemas::RunErrorKind::STAGE
        when Hive::ConfigError        then Hive::Schemas::RunErrorKind::CONFIG
        when Hive::AgentError         then Hive::Schemas::RunErrorKind::AGENT
        when Hive::GitError           then Hive::Schemas::RunErrorKind::GIT
        when Hive::WorktreeError      then Hive::Schemas::RunErrorKind::WORKTREE
        when Hive::AmbiguousSlug      then Hive::Schemas::RunErrorKind::AMBIGUOUS_SLUG
        when Hive::InternalError      then Hive::Schemas::RunErrorKind::INTERNAL
        else                               Hive::Schemas::RunErrorKind::GENERIC
        end
      end
    end
  end
end
