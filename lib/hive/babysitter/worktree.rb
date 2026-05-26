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
        run_git!("fetch", "origin", "pull/#{@pr.fetch('number')}/head:#{local_ref}")
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

      def head_ref
        @pr.fetch("headRefName")
      end

      def remove_existing!
        if File.directory?(path)
          Open3.capture3("git", "-C", @project.fetch("path"), "worktree", "remove", "--force", path)
          FileUtils.rm_rf(path)
        end
      end

      def run_git!(*args)
        out, err, status = Open3.capture3("git", "-C", @project.fetch("path"), *args)
        return if status.success?

        raise Hive::WorktreeError, "git #{args.join(' ')} failed: #{err.to_s.strip.empty? ? out : err}"
      end
    end
  end
end
