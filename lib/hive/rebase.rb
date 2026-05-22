require "yaml"
require "fileutils"
require "hive/git_ops"
require "hive/protected_files"
require "hive/stages/base"

module Hive
  # Auto-rebase pre-step for `hive run`. Detects when the task's
  # worktree branch is behind the project's default branch, fetches
  # origin's tip, attempts `git rebase`, and dispatches the project's
  # execute-stage agent to resolve any conflicts. Fail-soft on every
  # error path: `git rebase --abort` + `git reset --hard ORIG_HEAD`
  # restore the worktree to its pre-rebase state, the run continues
  # with a warning, and the operator can rebase manually if needed.
  #
  # Plan: `docs/plans/2026-05-14-001-feat-hive-auto-rebase-stale-worktree-plan.md`.
  # Originating incident: `i-want-to-be-able-260507-7682` REVIEW_STALE
  # pass=4 with phantom-deletion escalations after main moved forward
  # via PRs #63-#68 while the task's branch sat in 5-review.
  module Rebase
    # Hardcoded cap on conflict-resolution agent dispatches per
    # rebase invocation (S1 in the doc-review — not a config knob).
    # Projects with persistently high-conflict branches should
    # investigate the underlying drift, not raise the cap.
    MAX_CONFLICT_RESOLUTIONS = 5

    # Hive's per-task-folder protected files live in `task.folder`,
    # NOT in the worktree's git history. A `git rebase` against
    # `origin/<default>` operates on the worktree's tracked files,
    # so `plan.md`/`worktree.yml`/`task.md` cannot appear in
    # `staged_unmerged_files` by construction — the conflict check
    # against this constant was belt-and-suspenders that produced
    # false-positives on legitimate project files named `plan.md`
    # at the worktree root (PR #69 review B8). The real isolation
    # boundary is `add_dirs: []` on the conflict-resolution spawn,
    # which physically prevents the agent from reaching
    # `task.folder`. Kept as a frozen empty list rather than removed
    # so downstream callers that imported the constant don't break;
    # the actual check is gone from `resolve_conflicts`.
    PROTECTED_BASENAMES = [].freeze

    # Result of a single `perform` call. Consumed by JSON envelope
    # (U6) and stderr logging (U4). `reason` is nil on success; a
    # symbol naming the skip-or-failure cause otherwise. The 5-field
    # collapsed `Result` from the doc-review's S3 decision; in JSON
    # serialization `reason` may render as nil (success) or a string
    # (skip/failure).
    Result = Data.define(
      :attempted,
      :commits_behind,
      :succeeded,
      :agent_resolutions,
      :resolved_files,
      :reason,
      :post_rebase_warnings
    ) do
      def to_h_for_envelope
        {
          attempted: attempted,
          commits_behind: commits_behind,
          succeeded: succeeded,
          agent_resolutions: agent_resolutions,
          resolved_files: resolved_files,
          reason: reason && reason.to_s,
          post_rebase_warnings: post_rebase_warnings
        }
      end

      def self.disabled
        new(attempted: false, commits_behind: nil, succeeded: false,
            agent_resolutions: 0, resolved_files: [], reason: :disabled,
            post_rebase_warnings: [])
      end

      def self.skipped(reason)
        new(attempted: false, commits_behind: nil, succeeded: false,
            agent_resolutions: 0, resolved_files: [], reason: reason,
            post_rebase_warnings: [])
      end

      def self.no_op
        new(attempted: true, commits_behind: 0, succeeded: true,
            agent_resolutions: 0, resolved_files: [], reason: nil,
            post_rebase_warnings: [])
      end

      def self.succeeded(commits_behind:, agent_resolutions:, resolved_files:, post_rebase_warnings: [])
        new(attempted: true, commits_behind: commits_behind, succeeded: true,
            agent_resolutions: agent_resolutions, resolved_files: resolved_files,
            reason: nil, post_rebase_warnings: post_rebase_warnings)
      end

      def self.failed(reason:, commits_behind:, agent_resolutions:, resolved_files:)
        new(attempted: true, commits_behind: commits_behind, succeeded: false,
            agent_resolutions: agent_resolutions, resolved_files: resolved_files,
            reason: reason, post_rebase_warnings: [])
      end
    end

    module_function

    # Main entry point. `task` is a Hive::Task-shaped object that
    # responds to `worktree_path` and `folder`. `cfg` is the full
    # project config Hash. Returns a `Rebase::Result`. Never raises;
    # any internal exception is captured as `Result.failed(...)`.
    def perform(task, cfg)
      enabled = cfg.dig("rebase", "enabled")
      return Result.disabled if enabled == false

      worktree = task.worktree_path
      return Result.skipped(:no_worktree) if worktree.nil? || worktree.to_s.strip.empty?
      return Result.skipped(:no_worktree) unless File.directory?(worktree)

      git = Hive::GitOps.new(worktree)

      return Result.skipped(:pre_existing_rebase) if git.rebase_in_progress?
      return Result.skipped(:dirty_worktree) if git.dirty?
      return Result.skipped(:detached_head) if git.detached_head?

      default_branch = cfg["default_branch"] || git.default_branch
      return Result.skipped(:no_default_branch) if default_branch.nil? || default_branch.strip.empty?

      return Result.skipped(:fetch_failed) unless git.fetch_default_branch(default_branch)

      ref = "origin/#{default_branch}"
      commits_behind = git.commits_behind(ref)
      return Result.no_op if commits_behind.zero?

      run_rebase(task, cfg, git, ref, commits_behind)
    rescue Hive::GitError, SystemCallError, IOError => e
      # Narrow rescue: only catch I/O-class and git-class failures.
      # Programmer errors (NoMethodError, NameError, ArgumentError,
      # TypeError) deliberately escape so logic bugs surface in
      # operator logs instead of being misattributed to a generic
      # `unexpected_io_error` rebase failure. Mirrors the
      # recover_review rescue pattern pinned in PR #56.
      # Fixed reason (not class-name interpolated) so it fits the
      # closed schema enum — exception class is in stderr for
      # debugging, but not in the structured envelope.
      warn "[hive] rebase unexpected I/O error: #{e.class}: #{e.message}"
      Result.failed(reason: :unexpected_io_error,
                    commits_behind: nil,
                    agent_resolutions: 0,
                    resolved_files: [])
    end

    # Private helpers below — exposed via module_function only so
    # unit tests can drive them directly when useful. Production
    # callers should use `perform`.

    def run_rebase(task, cfg, git, ref, commits_behind)
      resolved_files = []

      begin
        git.rebase_onto(ref)
        warnings = []
        update_execute_base_head!(task, git, warnings)
        return Result.succeeded(commits_behind: commits_behind,
                                agent_resolutions: 0,
                                resolved_files: resolved_files,
                                post_rebase_warnings: warnings)
      rescue Hive::RebaseConflict
        # Fall through to the conflict-resolution loop below.
      rescue Hive::GitError => e
        warn "[hive] rebase failed (#{e.class}): #{e.message}; continuing with stale base"
        return Result.failed(reason: :rebase_failed,
                             commits_behind: commits_behind,
                             agent_resolutions: 0,
                             resolved_files: [])
      end

      resolve_conflicts(task, cfg, git, commits_behind, resolved_files)
    end

    def resolve_conflicts(task, cfg, git, commits_behind, resolved_files)
      profile = Hive::Stages::Base.stage_profile(cfg, "execute")
      if profile.nil?
        return abort_with(git, :no_conflict_agent_configured,
                          commits_behind, 0, resolved_files)
      end

      attempts = 0
      while git.rebase_in_progress?
        attempts += 1
        if attempts > MAX_CONFLICT_RESOLUTIONS
          return abort_with(git, :max_attempts_exceeded,
                            commits_behind, attempts - 1, resolved_files)
        end

        unmerged = git.staged_unmerged_files
        if unmerged.empty?
          # Defensive: rebase says in-progress but nothing unmerged.
          # Try `--continue` once; if that also fails, abort.
          begin
            git.rebase_continue
            next
          rescue Hive::RebaseConflict
            # Next replay produced conflicts; loop back.
            next
          rescue Hive::GitError, SystemCallError, IOError
            return abort_with(git, :rebase_continue_failed,
                              commits_behind, attempts - 1, resolved_files)
          end
        end

        # Note: the `PROTECTED_BASENAMES` check that previously fired
        # here was removed in PR #69 review B8. The protected files
        # (plan.md / worktree.yml / task.md) live in `task.folder`,
        # NOT in the worktree's git tree — they cannot appear in
        # `staged_unmerged_files` by construction. The real isolation
        # boundary is `add_dirs: []` on the conflict-resolution spawn
        # (set in `dispatch_conflict_agent`), which physically
        # prevents the agent from reaching `task.folder`.

        result = dispatch_conflict_agent(task, cfg, profile, git, unmerged)
        unless result[:status] == :ok
          detail = result[:error_message] || result[:status]
          warn "[hive] rebase conflict-resolution agent failed: #{detail}"
          return abort_with(git, :agent_failed,
                            commits_behind, attempts - 1, resolved_files)
        end

        unless git.rebase_in_progress?
          # Agent ran `git rebase --continue` itself against the
          # prompt directive (or git's auto-commit picked up the
          # resolved files). If `staged_unmerged_files` is empty AND
          # no conflict markers remain in the originally-unmerged
          # files, the rebase actually completed successfully —
          # accept the work rather than throwing it away. PR #69
          # review B9. The marker-scan iterates `unmerged` (the
          # paths git reported as conflicted BEFORE the agent ran),
          # NOT `staged_unmerged_files` (which is now empty by
          # definition since the rebase finished), so an agent that
          # `git add`ed files with markers still in them cannot
          # bypass the check. PR #69 review P1.
          remaining = git.staged_unmerged_files
          worktree_clean = !git.dirty?
          markers_in_resolved = unmerged.any? do |path|
            full = File.join(task.worktree_path, path)
            File.file?(full) && has_conflict_markers?(full)
          end
          if remaining.empty? && worktree_clean && !markers_in_resolved
            resolved_files.concat(unmerged)
            warn "[hive] conflict-resolution agent ran `git rebase --continue` itself; rebase completed cleanly so accepting the result"
            break
          end

          # Distinguish marker-bypass from a partial commit: markers
          # in the rebased history are a stronger signal than a
          # generic "agent continued without finishing."
          reason = markers_in_resolved ? :markers_remaining : :agent_called_continue_itself
          return abort_with(git, reason,
                            commits_behind, attempts - 1, resolved_files)
        end

        # Scan the originally-unmerged paths (captured into `unmerged`
        # before the agent ran), not just paths git still reports as
        # unmerged. The agent could `git add` a file with `<<<<<<<`
        # markers still in it — that file is "resolved" to git but
        # would commit markers into the rebased history. Iterating
        # over `unmerged` catches that bypass. Files the agent
        # legitimately resolved by deletion drop out via the
        # `File.file?` guard (no file, no markers). PR #69 review P1.
        markers_remaining = unmerged.any? do |path|
          full = File.join(task.worktree_path, path)
          File.file?(full) && has_conflict_markers?(full)
        end
        if markers_remaining
          return abort_with(git, :markers_remaining,
                            commits_behind, attempts - 1, resolved_files)
        end

        resolved_files.concat(unmerged)

        begin
          git.rebase_continue
        rescue Hive::RebaseConflict
          # Next commit in the replay also has conflicts; loop back.
          next
        rescue Hive::GitError, SystemCallError, IOError
          return abort_with(git, :rebase_continue_failed,
                            commits_behind, attempts - 1, resolved_files)
        end
      end

      # Post-loop contamination guard. The agent-called-continue-itself
      # branch above already requires `!git.dirty?` before accepting the
      # result, but the normal path (agent :ok → orchestrator runs
      # rebase_continue) never checked. If the agent staged its conflict
      # resolution AND left untracked scratch files (or modified files
      # outside the conflict set), git treats the rebase as successful
      # while the worktree carries contamination that later stages
      # would silently absorb. Fail-soft: abort and reset to ORIG_HEAD
      # so the next stage runs against the (stale) pre-rebase base
      # rather than the contaminated post-rebase tree.
      if git.dirty?
        return abort_with(git, :dirty_after_success,
                          commits_behind, attempts, resolved_files)
      end

      warnings = []
      update_execute_base_head!(task, git, warnings)
      Result.succeeded(commits_behind: commits_behind,
                       agent_resolutions: attempts,
                       resolved_files: resolved_files.uniq,
                       post_rebase_warnings: warnings)
    end

    def dispatch_conflict_agent(task, cfg, profile, git, conflict_files)
      timeout = cfg.dig("rebase", "conflict_resolution_timeout_sec") || 2700
      budget = cfg.dig("budget_usd", "execute_implementation") || 500

      Hive::Stages::Base.spawn_agent(
        task,
        prompt: render_conflict_prompt(task, cfg, git, conflict_files),
        max_budget_usd: budget,
        timeout_sec: timeout,
        add_dirs: [],
        cwd: task.worktree_path,
        log_label: "rebase_conflict",
        profile: profile,
        status_mode: :exit_code_only
      )
    end

    def render_conflict_prompt(task, cfg, git, conflict_files)
      tag = Hive::Stages::Base.user_supplied_tag
      template_path = Hive::Stages::Base.resolve_template_path(
        "rebase_conflict_resolution.md.erb",
        hive_state_dir: Hive::Stages::Base.hive_state_dir_for_task_folder(task.folder)
      )

      # PR #69 review B1: use the GitOps helper that resolves
      # `.git` correctly in linked worktrees (where it's a file,
      # not a directory). Previous hardcoded path silently fell
      # into the rescue on every production run.
      current_commit_msg = begin
        msg_path = git.rebase_merge_message_path
        msg_path ? File.read(msg_path).strip : "(commit message unavailable — rebase state file missing)"
      rescue SystemCallError, IOError
        "(commit message unavailable — rebase state file missing)"
      end

      # PR #69 review B10: use the cfg-resolved default branch so
      # the agent prompt's rebase-target name matches what hive
      # actually rebased against. Falls back to git's detection
      # only when cfg has no override.
      default_branch = cfg["default_branch"] || git.default_branch

      Hive::Stages::Base.render_resolved_path(
        template_path,
        Hive::Stages::Base::TemplateBindings.new(
          worktree_path: task.worktree_path,
          task_folder: task.folder,
          default_branch: default_branch,
          current_commit_msg: current_commit_msg,
          conflict_files: conflict_files,
          user_supplied_tag: tag
        )
      )
    end

    # Conflict-marker detector. Fails CLOSED (returns true) on read
    # errors so the safety gate around the conflict-resolution agent
    # defaults to "refuse to continue with unverified resolution"
    # rather than "trust the agent." PR #69 review B5 — silent
    # false-on-read-error was the wrong fail-soft direction here.
    def has_conflict_markers?(absolute_path)
      return true unless File.file?(absolute_path)  # unreadable / non-regular → assume conflict

      File.foreach(absolute_path) do |line|
        return true if line.start_with?("<<<<<<<", "=======", ">>>>>>>")
      end
      false
    rescue SystemCallError, IOError
      true  # fail-closed
    end

    def abort_with(git, reason, commits_behind, attempts, resolved_files)
      git.rebase_abort
      git.reset_hard_orig_head
      Result.failed(reason: reason,
                    commits_behind: commits_behind,
                    agent_resolutions: attempts,
                    resolved_files: resolved_files)
    end

    # U8: rewrite `execute_base_head` in `worktree.yml` after a
    # successful rebase. Without this, 4-execute continuation passes
    # trip `EXECUTE_WAITING(reason=head_not_descendant)` because the
    # stored pre-rebase SHA is no longer reachable in the rebased
    # commit graph. Silent no-op when worktree.yml doesn't exist
    # (e.g., task hasn't entered 4-execute yet). Failure of the
    # rewrite itself emits a stderr warning but does NOT fail the
    # rebase — the downstream stage will catch any inconsistency.
    def update_execute_base_head!(task, git, warnings = [])
      worktree_yml = File.join(task.folder, "worktree.yml")
      return unless File.exist?(worktree_yml)

      data = YAML.safe_load(File.read(worktree_yml), permitted_classes: [], aliases: false) || {}
      return unless data.is_a?(Hash)
      return unless data.key?("execute_base_head")

      new_sha = git.head_sha
      return if data["execute_base_head"] == new_sha

      data["execute_base_head"] = new_sha
      tmp = "#{worktree_yml}.tmp.#{Process.pid}.#{Time.now.to_i}"
      begin
        File.write(tmp, YAML.dump(data))
        File.rename(tmp, worktree_yml)
      rescue StandardError
        # Clean up the temp file on rename failure so it doesn't
        # accumulate as orphaned state.
        begin
          File.delete(tmp) if File.exist?(tmp)
        rescue StandardError
          # best-effort cleanup; nothing else to do
        end
        raise
      end
    rescue SystemCallError, IOError, Psych::Exception => e
      # Surface the failure both as a stderr warning (operator
      # sees it immediately) AND as a structured entry in
      # `post_rebase_warnings` (JSON envelope consumers + agents
      # can act on it). The rebase has SUCCEEDED at the git level;
      # only the worktree.yml rewrite failed. The next 4-execute
      # continuation pass may trip `head_not_descendant` until the
      # operator manually updates `execute_base_head`. PR #69 B6.
      msg = "execute_base_head not updated in worktree.yml: #{e.class}: #{e.message}"
      warn "[hive] #{msg}; the next execute pass may trip head_not_descendant — investigate manually"
      warnings << msg if warnings
    end
  end
end
