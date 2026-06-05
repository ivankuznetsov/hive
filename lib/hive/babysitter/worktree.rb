require "fileutils"
require "open3"

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
        FileUtils.mkdir_p(File.dirname(path))
        remove_existing!
        local_ref = "refs/hive-babysitter/pr-#{@pr.fetch('number')}"
        run_git!("fetch", "origin", "+pull/#{@pr.fetch('number')}/head:#{local_ref}")
        run_git!("worktree", "add", "-B", branch, path, local_ref)
        Result.new(path: path, branch: branch)
      end

      def path
        File.join(@project.fetch("hive_state_path"), "babysitter", "worktrees", @pr.fetch("number").to_s)
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

      def run_git!(*args)
        out, err, status = Open3.capture3("git", "-C", @project.fetch("path"), *args)
        return if status.success?

        raise Hive::WorktreeError, "git #{args.join(' ')} failed: #{err.to_s.strip.empty? ? out : err}"
      end
    end
  end
end
