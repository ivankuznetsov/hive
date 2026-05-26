require "hive/gh"

module Hive
  module Babysitter
    class ContextBuilder
      Context = Struct.new(
        :status_rollup,
        :failing_jobs,
        :diff_stat,
        :mergeable_state,
        :base_ref,
        :head_ref,
        :base_sha,
        :merge_base,
        :ahead,
        :behind,
        keyword_init: true
      )

      def self.build(worktree_path:, pr:, cfg:, byte_cap: 50 * 1024, status_rollup: nil)
        status = status_rollup || Hive::Gh.pr_status_rollup(worktree_path, pr.fetch("number"), cfg: cfg)
        failing_jobs = Hive::Gh.failing_jobs_with_logs(
          worktree_path,
          status,
          cfg: cfg,
          byte_cap: byte_cap
        )
        # Diff against the worktree's local HEAD, not the PR's headRefName:
        # the worktree checks out `hive-babysitter/pr-<n>` built from
        # `pull/<n>/head`, so the headRefName branch does not exist locally
        # (and never does for fork PRs). HEAD is correct for both.
        diff_stat = Hive::Gh.pr_diff_stat(
          worktree_path,
          pr.fetch("baseRefName"),
          "HEAD",
          cfg: cfg
        )
        divergence = Hive::Gh.pr_base_divergence(worktree_path, pr.fetch("baseRefName"), cfg: cfg)
        Context.new(
          status_rollup: status,
          failing_jobs: failing_jobs,
          diff_stat: diff_stat,
          mergeable_state: status["mergeable"],
          base_ref: pr.fetch("baseRefName"),
          head_ref: pr.fetch("headRefName"),
          base_sha: divergence["base_sha"],
          merge_base: divergence["merge_base"],
          ahead: divergence["ahead"],
          behind: divergence["behind"]
        )
      end
    end
  end
end
