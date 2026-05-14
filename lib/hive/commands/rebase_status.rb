require "json"
require "hive/task_resolver"
require "hive/config"
require "hive/git_ops"

module Hive
  module Commands
    # `hive rebase-status TARGET` — read-only inspector for the
    # auto-rebase pre-step. Reports whether a `hive run` would
    # attempt a rebase, how far behind the default branch the
    # worktree is, and what guards (if any) would short-circuit
    # the attempt. Never mutates anything; never runs `git fetch`
    # (that would mutate origin's refs locally and is a side
    # effect operators didn't ask for from a status verb). All
    # state is read from local git data.
    #
    # Originated from PR #69 review AGENT-O3: agents and operators
    # want a way to check "would hive rebase this task right now?"
    # without actually running it. Stays in lockstep with
    # `Hive::Rebase.perform`'s guard order so the answer is
    # accurate.
    class RebaseStatus
      def initialize(target, project: nil, stage: nil, json: false)
        @target = target
        @project_filter = project
        @stage_filter = stage
        @json = json
      end

      def call
        task = Hive::TaskResolver.new(
          @target,
          project_filter: @project_filter,
          stage_filter: @stage_filter
        ).resolve
        cfg = Hive::Config.load(task.project_root)

        status = inspect_status(task, cfg)
        @json ? emit_json(task, status) : emit_text(task, status)
      end

      private

      def inspect_status(task, cfg)
        enabled = cfg.dig("rebase", "enabled") != false
        return { state: :disabled, would_rebase: false } unless enabled

        worktree = task.worktree_path
        return { state: :no_worktree, would_rebase: false } if worktree.nil? || worktree.to_s.strip.empty?
        return { state: :no_worktree, would_rebase: false } unless File.directory?(worktree)

        git = Hive::GitOps.new(worktree)

        return { state: :pre_existing_rebase, would_rebase: false } if git.rebase_in_progress?
        return { state: :dirty_worktree, would_rebase: false } if git.dirty?
        return { state: :detached_head, would_rebase: false } if git.detached_head?

        default_branch = cfg["default_branch"] || git.default_branch
        return { state: :no_default_branch, would_rebase: false } if default_branch.nil? || default_branch.strip.empty?

        # Read-only: do NOT call fetch_default_branch. Use the
        # locally-known origin ref's tip — if origin is stale, the
        # status reflects what hive currently sees, which is what
        # `hive run` would see if fetch silently failed.
        ref = "origin/#{default_branch}"
        commits_behind = git.commits_behind(ref)
        return { state: :no_drift, would_rebase: false, commits_behind: 0, default_branch: default_branch } if commits_behind.zero?

        {
          state: :would_rebase,
          would_rebase: true,
          commits_behind: commits_behind,
          default_branch: default_branch
        }
      end

      def emit_text(task, status)
        case status[:state]
        when :disabled
          puts "#{task.slug}: auto-rebase DISABLED via cfg.rebase.enabled = false"
        when :no_worktree
          puts "#{task.slug}: no worktree at this stage (#{task.stage_name}); rebase not applicable"
        when :pre_existing_rebase
          puts "#{task.slug}: pre-existing rebase state on disk; rebase would skip. " \
               "Run `git -C #{task.worktree_path} rebase --abort` to clean up."
        when :dirty_worktree
          puts "#{task.slug}: worktree dirty; rebase would skip until clean"
        when :detached_head
          puts "#{task.slug}: detached HEAD; rebase would skip"
        when :no_default_branch
          puts "#{task.slug}: could not resolve default branch; rebase would skip"
        when :no_drift
          puts "#{task.slug}: 0 commits behind origin/#{status[:default_branch]}; nothing to rebase"
        when :would_rebase
          puts "#{task.slug}: #{status[:commits_behind]} commits behind origin/#{status[:default_branch]}; " \
               "next `hive run` would attempt rebase"
        end
      end

      def emit_json(task, status)
        payload = {
          "schema" => "hive-rebase-status",
          "slug" => task.slug,
          "stage" => task.stage_name,
          "folder" => task.folder,
          "worktree_path" => task.worktree_path,
          "state" => status[:state].to_s,
          "would_rebase" => status[:would_rebase],
          "commits_behind" => status[:commits_behind],
          "default_branch" => status[:default_branch]
        }
        puts JSON.generate(payload)
      end
    end
  end
end
