require "hive/agent_limit"

module Hive
  module ReviewErrorReason
    # The `reason=` vocabulary `mark_review_phase_failure` can stamp onto a
    # review_error marker, plus one reserved slot. Its limit arm writes
    # `limits_reached`; `classify` emits the CLASSIFIED subset below (plus the
    # always-available `unknown` fallback). `rate_limited` is reserved-but-
    # unemitted: it is accepted on read, but nothing in lib/ ever writes
    # `reason=rate_limited` (the gate only stamps `limits_reached`) — it is
    # kept so the enum tolerates the value without tripping the drift guards.
    #
    # This is NOT the complete set of review_error reasons: markers stamped
    # elsewhere in lib/ also carry ci_unrunnable, reviewer_partial_failure,
    # fix_status_check_failed, fix_tampered, and the phase=resume reasons.
    REASONS = %w[
      limits_reached
      rate_limited
      merge_conflict
      network_timeout
      tool_permission_denied
      agent_crashed
      unknown
    ].freeze

    # The regex tables driving `classify`. Order is priority — the first
    # reason with any line-level match wins.
    PATTERNS = [
      [
        "merge_conflict",
        [
          /conflict \(content\)/i,
          /merge conflict in /i,
          /automatic merge failed/i,
          /: needs merge\b/i,
          /you have unmerged paths/i,
          /fix conflicts and then commit/i,
          /rebase .*conflict/i
        ]
      ],
      [
        "network_timeout",
        [
          /\b(?:connection|connect|read|i\/o)\s*timed?\s*out/i,
          /\betimedout\b/i,
          /network is unreachable/i,
          /temporary failure in name resolution/i,
          /could not resolve host/i,
          /\beconnreset\b/i,
          /connection reset by peer/i
        ]
      ],
      [
        "tool_permission_denied",
        [
          /permission denied/i,
          /\beacces\b/i,
          /operation not permitted/i,
          /not allowed to (?:use|run|call)/i,
          /tool .* (?:denied|blocked|not permitted)/i,
          /refusing to run/i
        ]
      ],
      [
        "agent_crashed",
        [
          /\bsegmentation fault\b/i,
          /\bsigsegv\b/i,
          /\bsigabrt\b/i,
          /^panic:/i,
          /^fatal error:/i,
          /uncaught exception/i,
          /traceback \(most recent call last\)/i,
          /^killed\b/i,
          /core dumped/i,
          /\bsigkill\b/i
        ]
      ]
    ].freeze

    # The subset of REASONS that `classify` can actually emit (in addition to
    # the always-available `unknown` fallback). Derived from PATTERNS so the
    # lockstep invariant holds by construction — there is no hand-maintained
    # duplicate reason list to drift.
    CLASSIFIED = PATTERNS.map(&:first).uniq.freeze

    # The always-available fallback `classify` returns when no pattern fires.
    # Named (not a bare literal) so the load-time guard below covers it too —
    # otherwise the most-emitted value's membership in REASONS would rest only
    # on a hand-written literal and a unit test, not on a require-time check.
    FALLBACK = "unknown"

    # Load-time closed-enum guard: a PATTERNS row, or the fallback, keyed to a
    # reason absent from REASONS would let `classify` return a value outside
    # the enum. Fail at require time (one always-executed line) rather than
    # only under the suite.
    raise "ReviewErrorReason: emitted reasons escape REASONS: #{((CLASSIFIED + [ FALLBACK ]) - REASONS).inspect}" if ((CLASSIFIED + [ FALLBACK ]) - REASONS).any?

    module_function

    # Classify only residual, non-limit triage/fix agent failures. Provider
    # quota/rate walls are handled by AgentLimit first so they keep the
    # cooldown-based auto-heal path.
    def classify(error_message)
      text = Hive::AgentLimit.normalize(error_message)

      lines = text.each_line.map(&:strip).reject(&:empty?)
      PATTERNS.each do |reason, regexes|
        return reason if lines.any? { |line| regexes.any? { |regex| line.match?(regex) } }
      end

      FALLBACK
    end
  end
end
