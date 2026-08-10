require "fileutils"
require "open3"
require "securerandom"
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
        FileUtils.rm_rf(path)
        quarantine_cleanup_residue! if path_present?(path)

        _out, err, status = Open3.capture3(
          "git", "-C", @project.fetch("path"), "worktree", "prune", "--expire", "now"
        )
        return if status.success?

        raise Hive::WorktreeError, "git worktree prune failed: #{err.to_s.strip[0, 300]}"
      end

      def quarantine_cleanup_residue!
        root = File.join(File.dirname(File.dirname(path)), "quarantine", "worktrees")
        FileUtils.mkdir_p(root)
        destination = File.join(
          root,
          "pr-#{@pr.fetch('number')}-#{Time.now.utc.strftime('%Y%m%dT%H%M%S%6NZ')}-" \
          "#{Process.pid}-#{SecureRandom.hex(4)}"
        )
        File.rename(path, destination)
        warn "[hive] babysitter preserved cleanup residue at #{destination}"
        destination
      rescue SystemCallError => e
        raise Hive::WorktreeError,
              "cannot clear babysitter worktree path #{path}: " \
              "cleanup residue could not be quarantined (#{e.class}: #{e.message})"
      end

      def path_present?(candidate)
        File.lstat(candidate)
        true
      rescue Errno::ENOENT
        false
      end
    end
  end
end
