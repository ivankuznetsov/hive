require "fileutils"
require "open3"
require "hive/config"
require "hive/worktree"

module Hive
  module Babysitter
    class Worktree
      Result = Struct.new(:path, :branch, keyword_init: true)

      def self.materialize(project, pr)
        new(project, pr).materialize
      end

      def initialize(project, pr)
        @project = project
        @pr = pr
      end

      def materialize
        remove_existing!
        materialized = Hive::Worktree.materialize_pr(
          repo_root: @project.fetch("path"),
          pr_number: @pr.fetch("number"),
          path: path,
          branch: branch
        )
        Result.new(path: materialized.fetch(:path), branch: materialized.fetch(:branch))
      end

      def path
        state_path = Hive::Config.project_hive_state_path(@project)
        File.join(state_path, "babysitter", "worktrees", @pr.fetch("number").to_s)
      end

      def branch
        "hive-babysitter/pr-#{@pr.fetch('number')}"
      end

      private

      # Run `worktree remove` + `worktree prune` unconditionally rather than
      # gating on File.directory?(path): a prior run that crashed after
      # `worktree add` leaves orphan .git/worktrees/<pr>/ metadata even when
      # the on-disk path is gone, and the next `worktree add` would then fail
      # with "already exists in the worktree list" and wedge every subsequent
      # tick for this PR until an operator runs `git worktree prune` by hand.
      def remove_existing!
        Open3.capture3("git", "-C", @project.fetch("path"), "worktree", "remove", "--force", path)
        Open3.capture3("git", "-C", @project.fetch("path"), "worktree", "prune")
        FileUtils.rm_rf(path)
      end
    end
  end
end
