require "hive/git_ops"
require "hive/worktree"
require "open3"

module Hive
  module RefactorPatrol
    # Pins discovery to an exact committed default-branch snapshot without
    # consulting or mutating the operator's working checkout. When origin is
    # configured, a successful fetch is required so new jobs use remote trunk;
    # retries may supply their already-durable analysis SHA directly.
    class CheckoutGuard
      def initialize(project_root, default_branch:)
        @project_root = File.expand_path(project_root)
        @git = Hive::GitOps.new(project_root)
        @default_branch = default_branch.to_s
      end

      def validate_and_snapshot!(merge_sha:, analysis_sha: nil)
        analysis_sha = if analysis_sha.to_s.empty?
          current_default_sha!
        else
          resolve_commit!(analysis_sha, "analysis commit")
        end
        unless @git.ancestor?(merge_sha, analysis_sha)
          raise Hive::GitError, "analysis commit #{analysis_sha} does not contain merge commit #{merge_sha}"
        end

        { "analysis_sha" => analysis_sha }.freeze
      end

      private

      def current_default_sha!
        if Hive::Worktree.origin_configured?(@project_root)
          out, err, status = Hive::Worktree.fetch_origin_branch(
            @project_root, @default_branch
          )
          unless status.success?
            detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
            raise Hive::GitError,
                  "cannot fetch origin/#{@default_branch} for architecture patrol analysis: #{detail}"
          end
          return resolve_commit!(
            "refs/remotes/origin/#{@default_branch}", "remote default branch"
          )
        end

        resolve_commit!("refs/heads/#{@default_branch}", "local default branch")
      end

      def resolve_commit!(ref, label)
        out, err, status = Open3.capture3(
          "git", "-C", @project_root, "rev-parse", "--verify", "#{ref}^{commit}"
        )
        unless status.success?
          detail = err.to_s.strip.empty? ? out.to_s.strip : err.to_s.strip
          raise Hive::GitError, "#{label} #{ref.inspect} is unavailable: #{detail}"
        end

        out.strip
      end
    end
  end
end
