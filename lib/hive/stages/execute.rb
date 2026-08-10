require "digest"
require "fileutils"
require "hive/agent_limit"
require "hive/claude_launcher"
require "hive/dependencies"
require "hive/dependency_snapshot"
require "hive/artifact_firewall"
require "hive/stages/base"
require "hive/worktree"
require "hive/implementation_identity/store"
require "hive/git_ops"
require "hive/markers"
require "hive/plan_frontmatter"
require "hive/conditions/execute_boundary"

module Hive
  module Stages
    # 4-execute stage runner. Implementation-only since U9 split the
    # review pass out into the new 6-review stage.
    #
    # Flow per `hive run` on a 4-execute task:
    #   1. Pre-flight: terminal markers, worktree pointer health.
    #   2. If no worktree.yml: create the feature worktree at
    #      <worktree_root>/<slug>, write the pointer.
    #   3. Spawn the implementation agent with plan.md as context. The
    #      agent edits the worktree and commits.
    #   4. Finalize: SHA-protect plan.md / worktree.yml around the spawn.
    #      On clean spawn → set EXECUTE_COMPLETE; on tamper → :error.
    #
    # User then `mv`s the task folder to .hive-state/stages/6-review/
    # to enter the autonomous review loop. There is no review pass
    # inside 4-execute anymore — the orchestrator-owned terminal
    # marker is EXECUTE_COMPLETE on success.
    module Execute
      module_function

      # 4-execute owns plan.md and worktree.yml; task.md is owned but
      # the implementer agent writes the AGENT_WORKING marker into it,
      # so it's deliberately NOT in the SHA-protected set here.
      PROTECTED_FILES = %w[
        plan.md worktree.yml task-journal.jsonl task-projection.json
      ].freeze
      UNRESOLVED_IDENTITY = Object.new.freeze

      def run!(task, cfg)
        plan_path = File.join(task.folder, "plan.md")
        unless File.exist?(plan_path)
          warn "hive: plan.md missing; this task did not pass through 3-plan"
          exit 1
        end

        case task_state(task)
        when :complete
          warn "hive: already complete; mv this folder to 5-open-pr/ to continue"
          return { commit: nil, status: :execute_complete }
        when :worktree_missing
          warn "hive: worktree pointer present but worktree missing; recover with `git -C <root> worktree prune`, delete worktree.yml, then re-run"
          exit 1
        end

        identity = capture_implementation_identity(task, cfg)
        FileUtils.mkdir_p(task.reviews_dir)

        if File.exist?(task.worktree_yml_path)
          run_continuation_pass(task, cfg, identity)
        else
          run_init_pass(task, cfg, identity)
        end
      end

      # Pre-flight state. EXECUTE_STALE is no longer a state 4-execute
      # writes (the review pass moved to 6-review).
      def task_state(task)
        marker = Hive::Markers.current(task.state_file)
        return :complete if marker.name == :execute_complete

        if File.exist?(task.worktree_yml_path)
          pointer = Hive::Worktree.read_pointer(task.folder) || {}
          path = pointer["path"]
          return :worktree_missing unless path && File.directory?(path)
        end
        :ready
      end

      # Canonical worktree_root for a task — never derived from
      # agent-written pointer paths. Mirrors the path used at init time.
      def canonical_worktree_root(task, cfg)
        cfg["worktree_root"] || Hive::Worktree.default_worktree_root(File.basename(task.project_root))
      end

      # First entry into 4-execute: create the feature worktree, run
      # implementation, finalize.
      def run_init_pass(task, cfg, identity = UNRESOLVED_IDENTITY)
        identity = capture_implementation_identity(task, cfg) if identity.equal?(UNRESOLVED_IDENTITY)
        ops = Hive::GitOps.new(task.project_root)
        worktree_root = canonical_worktree_root(task, cfg)
        wt = Hive::Worktree.new(task.project_root, task.slug, worktree_root: worktree_root)
        # Consult config's `default_branch` first, falling back to the
        # detected branch — same precedence as 5-open-pr's
        # `dependency_pr_base_branch`, so both stacking call sites agree on
        # the base ref. The shared `DependencySnapshot.stacked_base`
        # resolves the prerequisite branch (or nil + a warn when a set
        # dependency doesn't resolve).
        default_branch = cfg["default_branch"] || ops.default_branch
        wt.create!(task.slug, default_branch: default_branch,
                              base_override: Hive::DependencySnapshot.stacked_base(task, default_branch))

        Hive::Worktree.validate_pointer_path(wt.path, worktree_root)
        wt.write_pointer!(task.folder, task.slug, execute_base_head: Hive::GitOps.new(wt.path).head_sha)

        write_initial_task_md(task)
        run_pass(task, cfg, wt.path, identity)
      end

      # User re-ran `hive run` on a 4-execute task whose worktree
      # already exists — re-validate the pointer and re-run the impl
      # spawn. Idempotent at the agent level (the agent re-reads
      # plan.md and continues / refines whatever was committed last
      # time).
      def run_continuation_pass(task, cfg, identity = UNRESOLVED_IDENTITY)
        identity = capture_implementation_identity(task, cfg) if identity.equal?(UNRESOLVED_IDENTITY)
        worktree_root = canonical_worktree_root(task, cfg)
        pointer = Hive::Worktree.read_owned_pointer(
          task.folder,
          project_root: task.project_root,
          slug: task.slug,
          expected_root: worktree_root
        )
        worktree_path = pointer.fetch("path")

        run_pass(task, cfg, worktree_path, identity)
      end

      # Spawn the implementation agent, SHA-protect plan.md /
      # worktree.yml around it, finalize EXECUTE_COMPLETE on clean
      # spawn or :error on tamper / agent failure.
      def run_pass(task, cfg, worktree_path, identity = UNRESOLVED_IDENTITY)
        identity = capture_implementation_identity(task, cfg) if identity.equal?(UNRESOLVED_IDENTITY)
        worktree_git = Hive::GitOps.new(worktree_path)
        baseline_head = execute_baseline_head(task, worktree_git)
        return worktree_git_failed(task, cfg, worktree_path) unless baseline_head

        custody_manifest = Hive::ArtifactFirewall::Manifest.new(
          root: task.folder,
          protected_anchors: PROTECTED_FILES,
          permitted_writable_roots: [ task.folder, worktree_path ]
        )
        custody_snapshot = Hive::ArtifactFirewall.capture(custody_manifest)
        begin
          impl_result = spawn_implementation(
            task, cfg, worktree_path, identity: identity
          )
        ensure
          custody_report = Hive::ArtifactFirewall.validate_and_restore(
            custody_manifest, custody_snapshot
          )
        end
        append_implementation_output(task, impl_result)

        if custody_report.tampered?
          return record_tamper(
            task, custody_report.tampered_labels, who: "implementer",
            restored: custody_report.restored?,
            restore_error: custody_report.restore_diagnostic
          )
        end

        if agent_failed?(impl_result)
          return mark_implementer_failure(task, cfg, impl_result, worktree_path, baseline_head)
        end

        worktree_state = inspect_worktree_state(task, worktree_git)
        return worktree_git_failed(task, cfg, worktree_path, baseline_head) unless worktree_state

        head_after = worktree_state.fetch(:head)
        current_branch = worktree_state.fetch(:branch)
        dirty_worktree = worktree_state.fetch(:dirty)
        expected_branch = expected_worktree_branch(task)
        new_commit = head_after != baseline_head
        # Research-mode parity across headless + tmux. Headless agents
        # may emit a :structured (JSON-stream `result` event) OR a
        # :plain (untagged stdout tail) final message; tmux runs in an
        # interactive pane and so always lands :plain. Either source is
        # acceptable proof that the agent said something coherent —
        # the source tag only matters for headless debugging.
        final_message_present = impl_result &&
                                %i[structured plain].include?(impl_result[:final_message_source]) &&
                                !impl_result[:final_message].to_s.strip.empty?

        unless current_branch == expected_branch
          return apply_execute_outcome(
            task, cfg, worktree_path, baseline_head,
            marker_name: :execute_waiting, attrs: { reason: "branch_mismatch" },
            commit: "execute_waiting_branch_mismatch", status: :execute_waiting,
            waiting_reason: "branch_mismatch"
          )
        end

        ancestor_ok = begin
          !new_commit || worktree_git.ancestor?(baseline_head, head_after)
        rescue Hive::GitError
          return worktree_git_failed(task, cfg, worktree_path, baseline_head)
        end

        if new_commit && !ancestor_ok
          return apply_execute_outcome(
            task, cfg, worktree_path, baseline_head,
            marker_name: :execute_waiting, attrs: { reason: "head_not_descendant" },
            commit: "execute_waiting_head_not_descendant", status: :execute_waiting,
            waiting_reason: "head_not_descendant"
          )
        end

        if dirty_worktree
          return apply_execute_outcome(
            task, cfg, worktree_path, baseline_head,
            marker_name: :execute_waiting, attrs: { reason: "dirty_worktree" },
            commit: "execute_waiting_dirty_worktree", status: :execute_waiting,
            waiting_reason: "dirty_worktree"
          )
        end

        research_mode = research_execution?(task)

        if research_mode && !new_commit && !final_message_present
          return apply_execute_outcome(
            task, cfg, worktree_path, baseline_head,
            marker_name: :execute_waiting, attrs: { reason: "missing_research_output" },
            commit: "execute_waiting_missing_research_output", status: :execute_waiting,
            waiting_reason: "missing_research_output", research: true
          )
        end

        unless new_commit || research_mode
          return apply_execute_outcome(
            task, cfg, worktree_path, baseline_head,
            marker_name: :execute_waiting, attrs: { reason: "no_worktree_changes" },
            commit: "execute_waiting_no_worktree_changes", status: :execute_waiting,
            waiting_reason: "no_worktree_changes"
          )
        end

        attrs = research_mode ? { mode: "research" } : {}
        apply_execute_outcome(
          task, cfg, worktree_path, baseline_head,
          marker_name: :execute_complete, attrs: attrs,
          commit: "execute_complete", status: :execute_complete,
          research: research_mode, research_evidence: final_message_present
        )
      end

      def apply_execute_outcome(task, cfg, worktree_path, baseline_head,
                                marker_name:, attrs:, commit:, status:, waiting_reason: nil,
                                research: false, research_evidence: false)
        outcome = Hive::Conditions::ExecuteBoundary.new(
          task: task, config: cfg, worktree_path: worktree_path
        ).evaluate(
          legacy_marker_name: marker_name,
          legacy_attrs: attrs,
          legacy_commit: commit,
          legacy_status: status,
          baseline_head: baseline_head,
          waiting_reason: waiting_reason,
          research: research,
          research_evidence: research_evidence
        )
        Hive::Markers.set(task.state_file, outcome.marker_name, outcome.marker_attrs)
        { commit: outcome.commit, status: outcome.status }
      end

      def agent_failed?(result)
        return true if result.nil?

        %i[error timeout].include?(result[:status])
      end

      def mark_implementer_failure(task, cfg, impl_result, worktree_path, baseline_head)
        if implementer_hit_limit?(impl_result)
          return apply_execute_outcome(
            task, cfg, worktree_path, baseline_head,
            marker_name: :error,
            attrs: {
              reason: "limits_reached",
              provider: implementation_provider(impl_result, cfg),
               message: "implementer hit a usage/credit limit",
               retry_after: Hive::AgentLimit.retry_after(text: implementer_limit_text(impl_result))
             },
            commit: "limits_reached", status: :error,
             waiting_reason: "agent_limit"
           )
        end

        apply_execute_outcome(
          task, cfg, worktree_path, baseline_head,
          marker_name: :error,
          attrs: {
            reason: "implementer_failed",
            provider: implementation_provider(impl_result, cfg),
            status: impl_result&.fetch(:status, nil),
            message: impl_result&.fetch(:error_message, nil)
          },
          commit: "implementer_failed", status: :error,
          waiting_reason: "agent_failure"
        )
      end

      def implementer_hit_limit?(impl_result)
        return false unless impl_result

        Hive::AgentLimit.limit_reached?(impl_result[:limit_text].to_s) ||
          Hive::AgentLimit.limit_reached?(impl_result[:error_message].to_s)
      end

      def implementer_limit_text(impl_result)
        text = impl_result&.fetch(:limit_text, nil).to_s
        text.empty? ? impl_result&.fetch(:error_message, nil).to_s : text
      end

      def execute_agent_name(cfg)
        Hive::Stages::Base.stage_profile(cfg, "execute").name.to_s
      rescue StandardError
        nil
      end

      def implementation_provider(result, cfg)
        result&.fetch(:implementation_provider, nil) || execute_agent_name(cfg)
      end

      def capture_implementation_identity(task, cfg)
        return nil unless Hive::Attempts::Context.current

        Hive::ImplementationIdentity::Store.new(task: task, cfg: cfg).capture_execute!
      end

      def spawn_implementation(task, cfg, worktree_path, identity: nil)
        plan_text = File.read(File.join(task.folder, "plan.md"))
        prompt = Hive::Stages::Base.render(
          "execute_prompt.md.erb",
          Hive::Stages::Base::TemplateBindings.new(
            project_name: File.basename(task.project_root),
            worktree_path: worktree_path,
            task_folder: task.folder,
            plan_text: plan_text,
            user_supplied_tag: Hive::Stages::Base.user_supplied_tag
          )
        )
        identity ||= capture_implementation_identity(task, cfg)
        profile = if identity
          Hive::AgentProfiles.lookup(identity.provider, cfg: cfg)
        else
          Hive::Stages::Base.stage_profile(cfg, "execute")
        end
        scope = Hive::Stages::Base.stage_permission_scope_or_mark!(
          cfg, "execute", task, profile,
          default_allowed_tools: Hive::ClaudeLauncher::IMPLEMENTER_ALLOWED_TOOLS
        )
        # 4-execute's lifecycle contract is "stage runner writes
        # EXECUTE_COMPLETE after a clean spawn" (see run_pass below),
        # not "the agent writes its own marker" — `templates/
        # execute_prompt.md.erb` explicitly forbids the agent from
        # touching the task.md marker. Headless runs nonetheless used
        # :state_file_marker because Hive::Agent#run! reads the marker
        # AFTER the agent exits to derive the envelope status, and the
        # rules around `Hive::Markers.current(...).name == :none` happen
        # to land :complete on a happy exit. Under tmux that path
        # cannot work: ClaudeLauncher.wait_for_terminal_marker
        # actively WAITS for the agent to stamp EXECUTE_COMPLETE and
        # times out when it doesn't. Use :exit_code_only here so the
        # runner gets a non-error envelope on a clean exit and applies
        # its own marker-write logic. Codex's profile default is
        # :output_file_exists; this pin overrides it for both modes.
        kwargs = {
          prompt: prompt,
          add_dirs: scope.fetch(:add_dirs),
          cwd: worktree_path,
          max_budget_usd: cfg.dig("budget_usd", "execute_implementation"),
          timeout_sec: cfg.dig("timeout_sec", "execute_implementation"),
          log_label: "execute-impl",
          profile: profile,
          **Hive::Stages::Base.tool_scope_kwargs(scope),
          status_mode: :exit_code_only,
          **Hive::Stages::Base.implementation_launch_arguments(identity, profile)
        }
        result = if profile.name == :claude
          Hive::Stages::Base.spawn_claude_with_tmux_marker!(
            task,
            cfg,
            **kwargs,
            session_name: Hive::ClaudeLauncher.tmux_session_name("4-execute", task) # coding-scoped: coding execute stage tmux session
          )
        else
          Hive::Stages::Base.spawn_agent(task, **kwargs)
        end
        result&.merge(implementation_provider: profile.name.to_s)
      end

      def record_tamper(task, tampered, who:, restored: false, restore_error: nil)
        Hive::Markers.set(task.state_file, :error,
                          reason: "#{who}_tampered",
                          files: tampered.join(","),
                          restored: restored,
                          restore_error: restore_error.to_s[0, 200])
        { commit: "#{who}_tampered", status: :error }
      end

      def write_initial_task_md(task)
        return if File.exist?(task.state_file)

        content = <<~MD
          ---
          slug: #{task.slug}
          started_at: #{Time.now.utc.iso8601}
          ---

          # #{task.slug}

          ## Implementation

          <!-- AGENT_WORKING -->
        MD
        File.write(task.state_file, content)
      end

      def execute_baseline_head(task, worktree_git)
        pointer = Hive::Worktree.read_pointer(task.folder) || {}
        pointer["execute_base_head"] || worktree_git.head_sha
      rescue Hive::GitError
        nil
      end

      def expected_worktree_branch(task)
        pointer = Hive::Worktree.read_pointer(task.folder) || {}
        pointer["branch"]
      end

      def inspect_worktree_state(_task, worktree_git)
        {
          head: worktree_git.head_sha,
          branch: worktree_git.current_branch,
          dirty: !worktree_git.status_short.strip.empty?
        }
      rescue Hive::GitError
        nil
      end

      def worktree_git_failed(task, cfg, worktree_path, baseline_head = nil)
        apply_execute_outcome(
          task, cfg, worktree_path, baseline_head,
          marker_name: :error, attrs: { reason: "worktree_git_failed" },
          commit: "execute_worktree_git_failed", status: :error,
          waiting_reason: "worktree_git_failed"
        )
      end

      def append_implementation_output(task, result)
        final_message = result && result[:final_message].to_s.strip
        return if final_message.empty?

        output = final_message.byteslice(0, 64 * 1024).scrub
        Hive::Markers.with_markers_lock(task.state_file) do
          content = File.exist?(task.state_file) ? File.read(task.state_file, encoding: "UTF-8") : ""
          insertion = "\n\n## Execute Output\n\n#{output}\n"
          marker_match = content.match(/\n<!-- [A-Z_]+(?: [^>]*)? -->\s*\z/)
          body = if marker_match
            content.sub(marker_match[0]) { "#{insertion}#{marker_match[0]}" }
          else
            "#{content.rstrip}#{insertion}"
          end
          Hive::Markers.write_atomic(task.state_file, body)
        end
      end

      def research_execution?(task)
        plan_path = File.join(task.folder, "plan.md")
        result = Hive::PlanFrontmatter.read(plan_path)
        result.valid? && result.data["execution_mode"].to_s == "research"
      end
    end
  end
end
