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

    # Hive's per-task-folder protected files (basename match) that
    # the rebase must abort on if they appear in the conflict set.
    # Mirrors `Hive::ProtectedFiles::ORCHESTRATOR_OWNED` deliberately
    # — `task.md` is included so the conflict-resolution agent can't
    # accidentally commit operator-facing prose conflicts.
    PROTECTED_BASENAMES = Hive::ProtectedFiles::ORCHESTRATOR_OWNED.dup.freeze

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
      :reason
    ) do
      def to_h_for_envelope
        {
          attempted: attempted,
          commits_behind: commits_behind,
          succeeded: succeeded,
          agent_resolutions: agent_resolutions,
          resolved_files: resolved_files,
          reason: reason && reason.to_s
        }
      end

      def self.disabled
        new(attempted: false, commits_behind: nil, succeeded: false,
            agent_resolutions: 0, resolved_files: [], reason: :disabled)
      end

      def self.skipped(reason)
        new(attempted: false, commits_behind: nil, succeeded: false,
            agent_resolutions: 0, resolved_files: [], reason: reason)
      end

      def self.no_op
        new(attempted: true, commits_behind: 0, succeeded: true,
            agent_resolutions: 0, resolved_files: [], reason: nil)
      end

      def self.succeeded(commits_behind:, agent_resolutions:, resolved_files:)
        new(attempted: true, commits_behind: commits_behind, succeeded: true,
            agent_resolutions: agent_resolutions, resolved_files: resolved_files,
            reason: nil)
      end

      def self.failed(reason:, commits_behind:, agent_resolutions:, resolved_files:)
        new(attempted: true, commits_behind: commits_behind, succeeded: false,
            agent_resolutions: agent_resolutions, resolved_files: resolved_files,
            reason: reason)
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
    rescue StandardError => e
      # Last-resort safety net. Any unexpected exception inside the
      # rebase machinery converts to a failure Result so the caller's
      # fail-soft contract holds. The stage runner still proceeds.
      Result.failed(reason: :"unexpected_error:#{e.class}",
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
        update_execute_base_head!(task, git)
        return Result.succeeded(commits_behind: commits_behind,
                                agent_resolutions: 0,
                                resolved_files: resolved_files)
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
          rescue StandardError
            return abort_with(git, :rebase_continue_failed,
                              commits_behind, attempts - 1, resolved_files)
          end
        end

        if unmerged.any? { |path| PROTECTED_BASENAMES.include?(File.basename(path)) }
          return abort_with(git, :protected_files_in_conflict,
                            commits_behind, attempts - 1, resolved_files)
        end

        result = dispatch_conflict_agent(task, cfg, profile, git, unmerged)
        unless result[:status] == :ok
          return abort_with(git, :agent_failed,
                            commits_behind, attempts, resolved_files)
        end

        unless git.rebase_in_progress?
          # Agent ran `git rebase --continue` itself against the prompt
          # directive. The rebase may have completed accidentally, but
          # we can't trust the result — abort and let the operator
          # rebase manually.
          return abort_with(git, :agent_called_continue_itself,
                            commits_behind, attempts, resolved_files)
        end

        remaining = git.staged_unmerged_files
        if remaining.any? { |path| has_conflict_markers?(File.join(task.worktree_path, path)) }
          return abort_with(git, :markers_remaining,
                            commits_behind, attempts, resolved_files)
        end

        resolved_files.concat(unmerged)

        begin
          git.rebase_continue
        rescue Hive::RebaseConflict
          # Next commit in the replay also has conflicts; loop back.
          next
        rescue StandardError
          return abort_with(git, :rebase_continue_failed,
                            commits_behind, attempts, resolved_files)
        end
      end

      update_execute_base_head!(task, git)
      Result.succeeded(commits_behind: commits_behind,
                       agent_resolutions: attempts,
                       resolved_files: resolved_files.uniq)
    end

    def dispatch_conflict_agent(task, cfg, profile, git, conflict_files)
      timeout = cfg.dig("rebase", "conflict_resolution_timeout_sec") || 2700
      budget = cfg.dig("budget_usd", "execute_implementation") || 500

      Hive::Stages::Base.spawn_agent(
        task,
        prompt: render_conflict_prompt(task, git, conflict_files),
        max_budget_usd: budget,
        timeout_sec: timeout,
        add_dirs: [],
        cwd: task.worktree_path,
        log_label: "rebase_conflict",
        profile: profile
      )
    end

    def render_conflict_prompt(task, git, conflict_files)
      tag = Hive::Stages::Base.user_supplied_tag
      template_path = Hive::Stages::Base.resolve_template_path(
        "rebase_conflict_resolution.md.erb",
        hive_state_dir: Hive::Stages::Base.hive_state_dir_for_task_folder(task.folder)
      )

      current_commit_msg = begin
        File.read(File.join(git.project_root, ".git", "rebase-merge", "message")).strip
      rescue StandardError
        "(commit message unavailable — rebase state file missing)"
      end

      Hive::Stages::Base.render_resolved_path(
        template_path,
        Hive::Stages::Base::TemplateBindings.new(
          worktree_path: task.worktree_path,
          task_folder: task.folder,
          default_branch: git.default_branch,
          current_commit_msg: current_commit_msg,
          conflict_files: conflict_files,
          protected_files: PROTECTED_BASENAMES,
          user_supplied_tag: tag
        )
      )
    end

    def has_conflict_markers?(absolute_path)
      return false unless File.file?(absolute_path)

      File.foreach(absolute_path) do |line|
        return true if line.start_with?("<<<<<<<", "=======", ">>>>>>>")
      end
      false
    rescue StandardError
      false
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
    def update_execute_base_head!(task, git)
      worktree_yml = File.join(task.folder, "worktree.yml")
      return unless File.exist?(worktree_yml)

      data = YAML.safe_load(File.read(worktree_yml), permitted_classes: [], aliases: false) || {}
      return unless data.is_a?(Hash)
      return unless data.key?("execute_base_head")

      new_sha = git.head_sha
      return if data["execute_base_head"] == new_sha

      data["execute_base_head"] = new_sha
      tmp = "#{worktree_yml}.tmp.#{Process.pid}.#{Time.now.to_i}"
      File.write(tmp, YAML.dump(data))
      File.rename(tmp, worktree_yml)
    rescue StandardError => e
      warn "[hive] failed to update worktree.yml execute_base_head after rebase: #{e.class}: #{e.message}; the next execute pass may trip head_not_descendant — investigate manually"
    end
  end
end
