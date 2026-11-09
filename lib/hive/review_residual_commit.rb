require "time"
require "hive/markers"

module Hive
  # 6-review's stage-exit invariant (CleanExit) commits a failed agent's
  # leftover edits as `chore(6-review): commit residual worktree changes`
  # AFTER the runner already recorded its failure marker and stopped
  # publishing. Nothing pushes that commit, so without a breadcrumb it is a
  # local-only fix the operator never hears about (the PR stays red while a
  # ready repair sits in the worktree).
  #
  # This module records the commit on the failure marker
  # (`residual_commit=<sha> residual_published=false`) and renders the
  # operator guidance. It deliberately never publishes: the residue skipped
  # the fix guardrail and the scope of a crashed agent's half-finished
  # turn is unknown, so the operator decides whether to keep it (a review
  # re-run reviews the branch including it and pushes through the guarded
  # review publication path) or drop it.
  module ReviewResidualCommit
    STAGE = "6-review".freeze # coding-scoped: residual commit surfacing applies only to the review stage
    # Markers that mean review stopped without publishing local HEAD.
    FAILURE_MARKERS = %i[review_error review_stale review_ci_stale error].freeze
    # Provider resets further out than this are worth routing around.
    LONG_LIMIT_SEC = 6 * 3600
    # Agent-role config keys selecting the agent profile per review phase.
    AGENT_ROLE_KEYS = { "fix" => "review.fix.agent", "ci" => "review.ci.agent" }.freeze

    module_function

    # Stamp the freshly created residual commit onto the failure marker the
    # runner left. Compare-and-swap against the observed marker so a
    # concurrent writer wins. Returns true when the marker was annotated.
    def annotate!(task, stage:, observed_marker:, head:)
      return false unless stage == STAGE
      return false unless observed_marker && FAILURE_MARKERS.include?(observed_marker.name)
      return false if head.to_s.empty?

      # The commit was created by this stage invocation after its last
      # publication attempt, so it cannot be on the PR head.
      notice = "residual commit #{head[0, 12]} is local-only (not on the PR head)"
      message = observed_marker.attrs["message"].to_s
      Hive::Markers.merge_attrs_if_current(
        task.state_file,
        observed: observed_marker,
        attrs: {
          "residual_commit" => head,
          "residual_published" => "false",
          "message" => message.empty? ? notice : "#{message}; #{notice}"
        }
      )
    end

    # Operator next step for a marker carrying an unpublished residual
    # commit, or nil when there is none.
    def next_step(marker, worktree:)
      sha = marker.attrs["residual_commit"].to_s
      return nil if sha.empty? || marker.attrs["residual_published"].to_s != "false"

      location = worktree.to_s.empty? ? "the task worktree" : worktree
      git = worktree.to_s.empty? ? "git" : "git -C #{worktree}"
      "residual commit #{sha} in #{location} holds the failed agent's leftover edits and is NOT on the PR; " \
        "inspect it (`#{git} show #{sha}`), then either keep it and re-run review (the next pass reviews the " \
        "branch including it and publishes through the guarded review publication path) or drop it " \
        "(`#{git} reset --keep #{sha}^`)"
    end

    # Hint for a fix/CI-fix agent parked on a provider limit that resets far
    # in the future. Text only: Hive switches agents automatically only when
    # the operator opted into `review.limit_fallback`; a marker that already
    # names a failed fallback attempt says so instead of suggesting it.
    def agent_profile_hint(marker, now: Time.now.utc)
      return nil unless marker.attrs["reason"].to_s == "limits_reached"
      return nil if marker.attrs["limit_source"].to_s == "hosted_ci"

      key = AGENT_ROLE_KEYS[marker.attrs["phase"].to_s]
      return nil unless key

      retry_after = Time.iso8601(marker.attrs["retry_after"].to_s)
      return nil if retry_after - now <= LONG_LIMIT_SEC

      hint = "the #{marker.attrs['phase']} agent's provider limit resets at #{retry_after.utc.iso8601}; to continue " \
             "sooner, point `#{key}` in the project's hive config at another agent profile, then retry (a " \
             "provider already pinned for the task's current input generation is kept until that generation advances)"
      hint + limit_fallback_hint(marker)
    rescue ArgumentError
      nil
    end

    def limit_fallback_hint(marker)
      fallback = marker.attrs["fallback_agent"].to_s
      if fallback.empty?
        ", or opt into `review.limit_fallback` so a long limit retries the role once on a fallback agent"
      else
        "; the configured limit fallback #{fallback} was tried and #{marker.attrs['fallback_outcome'] || 'failed'}"
      end
    end
  end
end
