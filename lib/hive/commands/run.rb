require "json"
require "hive/config"
require "hive/task"
require "hive/markers"
require "hive/lock"
require "hive/git_ops"
require "hive/agent"
require "hive/stages"
require "hive/stages/resolver"
require "hive/execute_waiting_action"
require "hive/task_action"
require "hive/task_resolver"
require "hive/dependency_snapshot"
require "hive/attempts/context"
require "hive/conditions/transition_guard"
require "hive/attempts/entrypoint"

module Hive
  module Commands
    class Run
      include Hive::Schemas::EnvelopeEmitter

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
      # `cleanup_instructions:` from the terminal `done` stage. See
      # schemas/hive-run.v1.json $defs.SuccessPayload.properties.
      OPTIONAL_PAYLOAD_KEYS = %w[cleanup_instructions].freeze

      def initialize(target, project: nil, stage: nil, json: false, quiet: false, no_rebase: false,
                     durable: false, attempt_entrypoint: nil)
        @target = target
        @project_filter = project
        @stage_filter = stage
        @json = json
        @quiet = quiet
        @no_rebase = no_rebase
        @durable = durable
        @attempt_entrypoint = attempt_entrypoint
      end

      def call
        call_with_envelope do
          @durable && !Hive::Attempts::Context.active? ? dispatch_durable : do_call
        end
      end

      def envelope_schema
        "hive-run"
      end

      def envelope_extras
        { "slug" => @target, "stage_filter" => @stage_filter }.compact
      end

      def envelope_error_kind(error)
        error_kind_for(error)
      end

      def do_call
        task = resolve_task
        Hive::Lock.with_task_lock(task.folder, slug: task.slug, stage: task.stage_name) do
          Hive::DependencySnapshot.enforce_admission!(task)
          Hive::Attempts::Context.current&.validate_generation!(task)
          cfg = Hive::Config.load(task.project_root)
          marker = Hive::Markers.current(task.state_file)
          if marker.name == :manual_steering
            @rebase_result = manual_steering_rebase_result
            report(task, { commit: nil, status: :manual_steering })
            return
          end

          @rebase_result = perform_rebase(task, cfg)
          runner = pick_runner(task)
          result = Hive::Stages::Base.with_stage_events(task, cfg: cfg) { runner.call(task, cfg) }
          commit_after(task, result)
          report(task, result)
        end
      end

      def resolve_task
        Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @stage_filter
        ).resolve
      end

      def dispatch_durable
        task = resolve_task
        result = (@attempt_entrypoint || Hive::Attempts::Entrypoint.new).dispatch(
          task: task,
          intended_stage: "#{task.stage_index}-#{task.stage_name}",
          argv: durable_worker_argv(task),
          interactive: true
        )
        handle_durable_failure!(result) unless result.exit_status.zero?

        result
      end

      def handle_durable_failure!(result)
        if result.status == :lost
          exit(result.exit_status) if @json && result.stdout_emitted?

          raise Hive::ConcurrentRunError,
                "durable attempt lost before producing a receipt for #{@target}: #{result.attempt_id}"
        end

        if @json && !result.stdout_emitted?
          raise Hive::AttemptExecutionError.new(
            "durable attempt #{result.attempt_id} finished with #{result.outcome || 'an error'} " \
            "(exit #{result.exit_status}) before emitting JSON",
            exit_code: result.exit_status,
            attempt_id: result.attempt_id,
            outcome: result.outcome
          )
        end

        exit(result.exit_status)
      end

      def durable_worker_argv(task)
        argv = [ "hive", "run", task.folder ]
        argv << "--json" if @json
        argv << "--no-rebase" if @no_rebase
        argv
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

      def manual_steering_rebase_result
        require "hive/rebase"

        Hive::Rebase::Result.skipped(:manual_steering)
      end

      def pick_runner(task)
        Hive::Stages::Resolver.resolve(task, descriptor: task.workflow)
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
        if marker.name == :execute_complete
          Hive::Conditions::TransitionGuard.validate!(
            task, config: Hive::Config.load(task.project_root)
          )
        end
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
          # - escalations-only (no reason or unknown reason): open the
          #   Q&A-style escalations file for the pass; answered Q/A
          #   blocks are consumed by the next fix pass.
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
          else
            target = pass_suffix ? "#{task.folder}/reviews/escalations-#{pass_suffix}.md" : task.folder
            { "kind" => kind::EDIT,
              "target" => target,
              "instructions" => "answer the open ### A1./A2. questions in #{File.basename(target)}; " \
                                "answered escalations are consumed by the next fix pass. " \
                                "For legacy reviewer files, `[x]` still marks an accepted auto-fix. Then re-run.",
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
        when :manual_steering
          { "kind" => Hive::Schemas::NextActionKind::NO_OP, "reason" => "manual_steering" }
        when :error
          # `ensure_clean_on_exit_failed` is the CleanExit invariant
          # refusing to auto-commit residue (scope-violation or git
          # failure). A bare `kind: no_op` strands agents: they have
          # neither the worktree path nor the residue paths to act
          # on. Surface an EDIT envelope mirroring the
          # `:review_error/fix_auto_commit_*` shape — target the
          # worktree root, echo `residue_paths` as a parsed array so
          # callers don't have to split the comma string themselves,
          # and include the canonical recovery one-liner so an agent
          # can shell-exec it directly. Other `:error` reasons keep
          # the generic NO_OP fallthrough.
          if marker.attrs["reason"].to_s == "ensure_clean_on_exit_failed"
            target = task.respond_to?(:worktree_path) && task.worktree_path ? task.worktree_path : task.folder
            residue_paths = marker.attrs["residue_paths"].to_s.split(",").map(&:strip).reject(&:empty?)
            verb = friendly_command(task, marker)
            return {
              "kind" => Hive::Schemas::NextActionKind::EDIT,
              "target" => target,
              "reason" => "ensure_clean_on_exit_failed",
              "residue_paths" => residue_paths,
              "error" => marker.attrs,
              "instructions" => "commit or discard the residue paths in #{target}, " \
                                "then `hive markers clear #{task.folder} --name ERROR --match-attr reason=ensure_clean_on_exit_failed` " \
                                "and re-run",
              "markers_to_clear" => [ "error" ],
              "rerun_with" => verb
            }
          end

          { "kind" => Hive::Schemas::NextActionKind::NO_OP, "error" => marker.attrs }
        when :review_error
          # Surface phase + reason from the marker so polling agents can
          # branch on the structured payload without parsing the marker
          # themselves. Echoes every other attr (pass, files, …) under
          # "error" so no signal is lost.
          if marker.attrs["reason"].to_s == "fix_auto_commit_scope_failed"
            relative = marker.attrs["files"].to_s.split(/[,\s]+/).find do |candidate|
              !candidate.empty? && !candidate.include?("..") && !candidate.start_with?("/")
            end
            target = relative ? File.join(task.folder, relative) : task.folder
            return {
              "kind" => Hive::Schemas::NextActionKind::EDIT,
              "target" => target,
              "phase" => marker.attrs["phase"],
              "reason" => marker.attrs["reason"],
              "error" => marker.attrs,
              "instructions" => "inspect the auto-commit scope artifact and worktree changes; " \
                                "remove/revert rejected files or adjust review.fix.auto_commit.scope_check, " \
                                "then clear REVIEW_ERROR and re-run",
              "rerun_with" => "hive run #{task.folder}"
            }
          end

          if %w[fix_auto_commit_sign_policy_failed fix_auto_commit_signing_failed].include?(marker.attrs["reason"].to_s)
            target = task.respond_to?(:worktree_path) && task.worktree_path ? task.worktree_path : task.folder
            return {
              "kind" => Hive::Schemas::NextActionKind::EDIT,
              "target" => target,
              "phase" => marker.attrs["phase"],
              "reason" => marker.attrs["reason"],
              "error" => marker.attrs,
              "instructions" => "inspect the fix-agent worktree changes and signing config; " \
                                "manually commit or revert remaining worktree changes before clearing REVIEW_ERROR; " \
                                "fix signing or adjust review.fix.auto_commit.sign_policy before re-running"
            }
          end

          if marker.attrs["reason"].to_s == "reviewer_partial_failure"
            pass = marker.attrs["pass"].to_s
            pass_suffix = pass.match?(/\A\d+\z/) ? format("%02d", pass.to_i) : nil
            target = pass_suffix ? "#{task.folder}/reviews/errors-#{pass_suffix}.md" : task.folder
            return {
              "kind" => Hive::Schemas::NextActionKind::EDIT,
              "target" => target,
              "phase" => marker.attrs["phase"],
              "reason" => marker.attrs["reason"],
              "error" => marker.attrs,
              "instructions" => "one or more reviewers failed for this pass; inspect " \
                                "#{File.basename(target)} for the failing reviewer, then either re-run " \
                                "hoping for recovery or clear the marker via " \
                                "`hive markers clear #{task.folder} --name REVIEW_ERROR` to accept partial coverage",
              "rerun_with" => "hive run #{task.folder}"
            }
          end

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
          # terminal `done` stage returns the cleanup lines as data; the human path
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
          puts "  next: answer open questions in reviews/escalations-NN.md; legacy reviewer files still accept [x], " \
               "then `hive run #{task.folder}`"
        when :review_stale
          puts "  next: if highest-pass reviewer files lack escalations-NN.md, remove REVIEW_STALE and re-run; " \
               "otherwise edit/rename highest-pass review files, remove REVIEW_STALE, then re-run"
        when :review_ci_stale
          puts "  next: fix CI failures, edit reviews/ci-blocked.md, remove the REVIEW_CI_STALE marker, then re-run"
        when :manual_steering
          puts "  next: manual steering active; automated run skipped"
        when :error, :review_error
          warn "  status: ERROR (#{marker.attrs.inspect})"
          if marker.name == :review_error
            phase = marker.attrs["phase"]
            reason = marker.attrs["reason"]
            warn "  phase: #{phase}" if phase
            warn "  reason: #{reason}" if reason
            if reason.to_s == "reviewer_partial_failure"
              pass = marker.attrs["pass"].to_s
              pass_suffix = pass.match?(/\A\d+\z/) ? format("%02d", pass.to_i) : nil
              detail = pass_suffix ? "reviews/errors-#{pass_suffix}.md" : "reviews/"
              warn "  next: inspect #{detail} for the failing reviewer, then re-run for recovery or clear " \
                   "the marker via `hive markers clear #{task.folder} --name REVIEW_ERROR` to accept partial coverage"
            else
              warn "  next: investigate; clear the marker via " \
                   "`hive markers clear #{task.folder} --name REVIEW_ERROR`; re-run"
            end
          end
          raise Hive::TaskInErrorState, "stage recorded :#{marker.name} (#{marker.attrs.inspect})"
        end
      end

      def next_stage_dir(task)
        next_stage = task.workflow.next_stage_after(task.stage_name)
        return nil unless next_stage

        File.join(task.hive_state_path, "stages", next_stage.dir)
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
        when Hive::DependencyWaitError then Hive::Schemas::RunErrorKind::DEPENDENCY_WAIT
        when Hive::DependencyAdmissionError then Hive::Schemas::RunErrorKind::ADMISSION_ERROR
        when Hive::ConfigError        then Hive::Schemas::RunErrorKind::CONFIG
        when Hive::AgentError         then Hive::Schemas::RunErrorKind::AGENT
        when Hive::GitError           then Hive::Schemas::RunErrorKind::GIT
        when Hive::WorktreeError      then Hive::Schemas::RunErrorKind::WORKTREE
        when Hive::AmbiguousSlug      then Hive::Schemas::RunErrorKind::AMBIGUOUS_SLUG
        when Hive::InvalidTaskPath    then Hive::Schemas::RunErrorKind::INVALID_TASK_PATH
        when Hive::InternalError, Hive::AttemptExecutionError
          Hive::Schemas::RunErrorKind::INTERNAL
        else                               Hive::Schemas::RunErrorKind::ERROR
        end
      end
    end
  end
end
