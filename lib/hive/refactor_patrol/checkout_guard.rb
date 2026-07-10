require "hive/git_ops"

module Hive
  module RefactorPatrol
    # Pins discovery to the operator's registered trunk checkout without ever
    # pulling, switching, resetting, or otherwise repairing it.
    class CheckoutGuard
      def initialize(project_root, default_branch:)
        @git = Hive::GitOps.new(project_root)
        @default_branch = default_branch.to_s
      end

      def validate_and_snapshot!(merge_sha:)
        validate_checkout!
        analysis_sha = @git.head_sha
        unless @git.ancestor?(merge_sha, analysis_sha)
          raise Hive::GitError, "registered checkout does not contain merge commit #{merge_sha}"
        end

        { "analysis_sha" => analysis_sha, "branch" => @default_branch, "status" => "" }.freeze
      end

      def assert_unchanged!(snapshot)
        validate_checkout!
        current = @git.head_sha
        return true if current == snapshot.fetch("analysis_sha")

        raise Hive::GitError,
              "registered checkout HEAD moved during refactor patrol review " \
              "(#{snapshot.fetch('analysis_sha')} -> #{current})"
      end

      private

      def validate_checkout!
        branch = @git.current_branch
        raise Hive::GitError, "registered checkout is detached" if branch.nil?
        unless branch == @default_branch
          raise Hive::GitError,
                "registered checkout is on #{branch.inspect}, expected default branch #{@default_branch.inspect}"
        end
        dirty = @git.status_short.lines.reject do |line|
          path = line.length > 3 ? line[3..].to_s.strip : ""
          path == ".hive-state" || path.start_with?(".hive-state/")
        end
        raise Hive::GitError, "registered checkout is dirty" unless dirty.empty?
      end
    end
  end
end
