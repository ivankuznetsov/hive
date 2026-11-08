require "fileutils"
require "open3"
require "tmpdir"
require "hive/plan_review"
require "hive/secret_patterns"

module Hive
  module PlanReview
    # One disposable detached checkout boundary for every plan-review agent.
    # Review and planner-revision agents both need a real Git checkout (Codex
    # refuses a plain temp directory) while their writes must stay away from
    # the live project tree.
    class DisposableWorktree
      DEFAULT_PREFIX = "hive-plan-review-worktree-".freeze

      attr_reader :path

      def self.open(project_root:, prefix: DEFAULT_PREFIX, revision: nil)
        worktree = new(project_root:, prefix:, revision:)
        yield worktree.create
      ensure
        worktree&.cleanup
      end

      # The revision a coding task will execute from: `origin/<default>` after a
      # quick fetch, falling back to the local default branch, exactly as
      # Hive::Worktree#create! bases a new feature worktree. Planning and review
      # must inspect that revision, not the project checkout's HEAD, which can
      # be an unrelated branch far behind the default or carry local edits.
      def self.execution_base(project_root)
        require "hive/config"
        require "hive/git_ops"
        require "hive/worktree"
        root = File.expand_path(project_root.to_s)
        cfg = begin
          Hive::Config.load(root)
        rescue StandardError
          {}
        end
        branch = cfg["default_branch"] || Hive::GitOps.new(root).default_branch
        Hive::Worktree.new(root, "plan-review-base").freshest_base(branch)
      rescue StandardError
        "HEAD"
      end

      def initialize(project_root:, prefix: DEFAULT_PREFIX, revision: nil)
        @project_root = File.expand_path(project_root.to_s)
        @revision = revision
        @prefix = prefix.to_s
        @temp_root = nil
        @path = nil
        @added = false
      end

      def create
        @temp_root = Dir.mktmpdir(@prefix)
        @path = File.join(@temp_root, "checkout")
        out, err, status = Open3.capture3(
          "git", "-C", @project_root, "worktree", "add", "--detach", @path,
          @revision || self.class.execution_base(@project_root)
        )
        unless status.success?
          raise InvalidRecord,
                "plan review could not create a disposable Git worktree: " \
                "#{Hive::SecretPatterns.redact([ out, err ].join(' ').strip)}"
        end

        @added = true
        @path
      rescue StandardError
        cleanup
        raise
      end

      def cleanup
        return unless @temp_root

        removal_failed = false
        if @added && @path
          _out, err, status = Open3.capture3(
            "git", "-C", @project_root, "worktree", "remove", "--force", @path
          )
          unless status.success?
            removal_failed = true
            warn "[hive.plan_review] disposable worktree cleanup failed: #{err.to_s.strip}"
          end
        end
        FileUtils.remove_entry_secure(@temp_root) if File.directory?(@temp_root)
        if removal_failed
          Open3.capture3(
            "git", "-C", @project_root, "worktree", "prune", "--expire", "now"
          )
        end
      rescue SystemCallError => error
        warn "[hive.plan_review] disposable worktree cleanup failed: " \
             "#{error.class}: #{error.message}"
      ensure
        @temp_root = nil
        @path = nil
        @added = false
      end
    end
  end
end
