require "json"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"
require "hive/agent"
require "hive/stages"
require "hive/execute_waiting_action"
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
        schema schema_version ok slug stage stage_index folder state_file
        marker attrs commit_action next_action rebase
      ].freeze

      # Optional top-level keys allowed in the SuccessPayload. They're emitted
      # only when the runner result carries the corresponding data — currently
      # `cleanup_instructions:` from the 7-done stage. See
      # schemas/hive-run.v1.json $defs.SuccessPayload.properties.
      OPTIONAL_PAYLOAD_KEYS = %w[cleanup_instructions].freeze

      def initialize(target, project: nil, stage: nil, json: false, quiet: false, no_rebase: false)
        @target = target
        @project_filter = project
        @stage_filter = stage
        @json = json
        @quiet = quiet
        @no_rebase = no_rebase
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
          @rebase_result = perform_rebase(task, cfg)
          runner = pick_runner(task)
          result = runner.call(task, cfg)
          commit_after(task, result)
          report(task, result)
        end
      end

      # Auto-rebase pre-step. Fail-soft: any failure aborts the rebase
      # and we proceed to the stage runner against the (stale) base.
      # See lib/hive/rebase.rb and
      # docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md.
      def perform_rebase(task, cfg)
        require "hive/rebase"
        # `--no-rebase` flag: one-off override of `cfg.rebase.enabled`.
        # Use the same shape as the cfg-disabled path so JSON consumers
        # see the disabled result; distinguish by reason for ops debugging.
        if @no_rebase
          result = Hive::Rebase::Result.skipped(:cli_override)
        else
          result = Hive::Rebase.perform(task, cfg)
        end
        log_rebase_outcome(task, result)
        result
      end

      def log_rebase_outcome(task, result)
        # `pre_existing_rebase` is a skip-state (attempted=false) but is
        # the ONE skip-state operators need to see explicitly: a stale
        # rebase-merge directory means a prior run aborted mid-flight
        # and the worktree needs manual cleanup. Surface this BEFORE
        # the attempted-guard. PR #69 review P2.
        if result.reason == :pre_existing_rebase
          warn "[hive] rebase skipped (pre_existing_rebase): #{task.worktree_path} has a mid-rebase state on disk. " \
               "Run `git -C #{task.worktree_path} rebase --abort` to clean up, then re-run."
          return
        end

        return unless result.attempted

        if result.succeeded
          if result.commits_behind && result.commits_behind > 0
            agent_part =
              if result.agent_resolutions > 0
                " (#{result.agent_resolutions} conflict#{'s' if result.agent_resolutions != 1} resolved by agent)"
              else
                ""
              end
            warn "[hive] rebased #{result.commits_behind} commits from origin onto #{task.slug} branch#{agent_part}"
          end
          # Always surface post-rebase warnings — these mean the
          # rebase itself succeeded but a follow-up step (e.g.,
          # worktree.yml write) failed, so the operator needs to know.
          (result.post_rebase_warnings || []).each do |w|
            warn "[hive] post-rebase warning: #{w}"
          end
        else
          warn "[hive] rebase attempt failed (#{result.reason}); continuing with stale base. Manual rebase recommended: " \
               "cd #{task.worktree_path} && git rebase origin/<default-branch>"
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
          # raise on :error AND :review_error markers so composing callers
          # (StageAction with quiet: @json) can surface them in their own
          # envelope. Without :review_error here, review stages run via
          # composing verbs would silently swallow the failure marker.
          if [ :error, :review_error ].include?(marker.name)
            raise Hive::TaskInErrorState, "stage recorded :#{marker.name} (#{marker.attrs.inspect})"
          end
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
          "ok" => true,
          "slug" => task.slug,
          "stage" => task.stage_name,
          "stage_index" => task.stage_index,
          "folder" => task.folder,
          "state_file" => task.state_file,
          "marker" => marker.name.to_s,
          "attrs" => marker.attrs,
          "commit_action" => result.is_a?(Hash) ? result[:commit] : nil,
          "next_action" => json_next_action(task, marker),
          "rebase" => rebase_envelope_block
        }
        # Build the emitted hash strictly in REQUIRED_PAYLOAD_KEYS order so
        # adding a key to one without the other is a load-time error rather
        # than silent schema drift.
        payload = REQUIRED_PAYLOAD_KEYS.to_h { |key| [ key, values.fetch(key) ] }
        if result.is_a?(Hash) && result[:cleanup_instructions]
          payload["cleanup_instructions"] = result[:cleanup_instructions]
        end
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

      # JSON envelope block for the auto-rebase pre-step. Always present
      # (even when rebase was disabled / never ran), so consumers can rely
      # on the key existing. See lib/hive/rebase.rb and U6 in
      # docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md.
      def rebase_envelope_block
        if @rebase_result
          @rebase_result.to_h_for_envelope.transform_keys(&:to_s)
        else
          # Defensive: should never fire in practice — perform_rebase runs
          # before report_json. Emit the "disabled" shape so the envelope
          # is well-formed regardless.
          {
            "attempted" => false,
            "commits_behind" => nil,
            "succeeded" => false,
            "agent_resolutions" => 0,
            "resolved_files" => [],
            "reason" => "disabled",
            "post_rebase_warnings" => []
          }
        end
      end

      def json_next_action(task, marker)
        kind = Hive::Schemas::NextActionKind
        case marker.name
        when :waiting
          { "kind" => kind::EDIT, "target" => task.state_file, "rerun_with" => friendly_command(task, marker) }
        when :execute_waiting
          execute_waiting_next_action(task, marker)
        when *Hive::Markers::TERMINAL_MARKER_NAMES
          approve_action(task, next_stage_dir(task))
        when :execute_stale
          { "kind" => kind::RECOVER_STALE,
            "instructions" => "edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run" }
        when :review_waiting
          # ce-review round-3 P2 #5 — branch the JSON envelope on
          # marker.attrs["reason"] so agents reading the contract get
          # a target+instructions pair specific to the resume gate:
          # - reason=fix_guardrail: open reviews/fix-guardrail-NN.md;
          #   approval requires every checkbox `[x]` AND the count
          #   matches marker.matches AND the worktree HEAD still
          #   matches marker.head.
          # - reason=reviewer_partial_failure: read reviews/errors-NN.md;
          #   either fix the reviewer config and re-run, or clear the
          #   marker to accept partial coverage.
          # - escalations-only (no reason or unknown reason): the
          #   legacy reviewers/escalations file-set per pass.
          reason = marker.attrs["reason"].to_s
          pass = marker.attrs["pass"].to_s
          pass_suffix = pass.match?(/\A\d+\z/) ? format("%02d", pass.to_i) : nil
          case reason
          when "fix_guardrail"
            target = pass_suffix ? "#{task.folder}/reviews/fix-guardrail-#{pass_suffix}.md" : task.folder
            { "kind" => kind::EDIT,
              "target" => target,
              "instructions" => "review every finding in #{File.basename(target)}; tick every `[ ]` " \
                                "to `[x]` to approve the guarded commits and advance the pass " \
                                "(partial ticks keep the pause), then re-run. " \
                                "Approval is rejected if the file's checkbox count " \
                                "differs from marker.matches or the worktree HEAD differs from marker.head.",
              "rerun_with" => "hive run #{task.folder}" }
          when "reviewer_partial_failure"
            target = pass_suffix ? "#{task.folder}/reviews/errors-#{pass_suffix}.md" : task.folder
            { "kind" => kind::EDIT,
              "target" => target,
              "instructions" => "one or more reviewers failed for this pass; either re-run hoping for " \
                                "recovery or `hive markers clear #{task.folder} --name REVIEW_WAITING` " \
                                "to accept the partial coverage, then re-run",
              "rerun_with" => "hive run #{task.folder}" }
          else
            { "kind" => kind::EDIT,
              "target" => task.folder,
              "instructions" => "toggle [x] on findings in reviews/*-NN.md or reviews/escalations-NN.md, then re-run",
              "rerun_with" => "hive run #{task.folder}" }
          end
        when :review_stale
          { "kind" => kind::RECOVER_STALE,
            "instructions" => "if highest-pass reviewer files lack escalations-NN.md, remove the REVIEW_STALE " \
                              "marker and re-run to retry that pass; otherwise edit/rename highest-pass review " \
                              "files, remove the marker, then re-run",
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

      def execute_waiting_next_action(task, marker)
        Hive::ExecuteWaitingAction.build(task, marker, rerun_with: friendly_command(task, marker))
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

      def report_text(task, result, marker)
        if result.is_a?(Hash) && result[:cleanup_instructions]
          # 7-done stage returns the cleanup lines as data; the human path
          # renders them on stdout while --json embeds them in the envelope.
          # See lib/hive/stages/done.rb.
          puts result[:cleanup_instructions]
        end
        puts "hive: marker=#{marker.name}"
        puts "  state_file: #{task.state_file}"
        case marker.name
        when :waiting
          puts "  next: edit the file, then `#{friendly_command(task, marker)}` again"
        when :execute_waiting
          puts "  next: #{execute_waiting_next_action(task, marker)["instructions"]}; " \
               "then `#{friendly_command(task, marker)}`"
        when *Hive::Markers::TERMINAL_MARKER_NAMES
          command = friendly_command(task, marker)
          puts "  next: #{command}" if command
        when :execute_stale
          puts "  next: edit reviews/, lower task.md frontmatter pass:, remove EXECUTE_STALE marker, re-run"
        when :review_waiting
          puts "  next: toggle [x] on findings in reviews/*-NN.md or reviews/escalations-NN.md, " \
               "then `hive run #{task.folder}`"
        when :review_stale
          puts "  next: if highest-pass reviewer files lack escalations-NN.md, remove REVIEW_STALE and re-run; " \
               "otherwise edit/rename highest-pass review files, remove REVIEW_STALE, then re-run"
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
        # `stage_filter` carries the user-supplied `--stage` value (input);
        # the structured `current_stage`/`target_stage` fields populated by
        # ErrorEnvelope.build for WrongStage describe the resolved stage
        # context (output). They live in different keys so an agent can read
        # `payload.stage_filter` without ambiguity.
        extras = { "slug" => @target, "stage_filter" => @stage_filter }.compact
        payload = Hive::Schemas::ErrorEnvelope.build(
          schema: "hive-run",
          error: error,
          error_kind: error_kind_for(error),
          extras: extras
        )
        puts JSON.generate(payload)
        @stdout_written = true
      rescue Errno::EPIPE, JSON::GeneratorError
        # Consumer closed the pipe (`hive run --json | jq -e ...` exiting
        # early) or the error message contained non-encodable bytes (a
        # subprocess stderr proxy with binary garbage). Swallow the emit
        # failure so the original Hive::Error still propagates with its
        # documented exit_code via bin/hive's outer rescue. The agent loses
        # the structured envelope on this path but still receives the exit
        # code, which is the load-bearing failure signal.
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
        when Hive::InvalidTaskPath    then Hive::Schemas::RunErrorKind::INVALID_TASK_PATH
        when Hive::InternalError      then Hive::Schemas::RunErrorKind::INTERNAL
        else                               Hive::Schemas::RunErrorKind::ERROR
        end
      end
    end
  end
end
