require "hive/agent_limit"

module Hive
  module ReviewErrorReason
    # The complete `reason=` vocabulary a review_error marker can carry. NOT
    # all of these are produced here: `limits_reached`/`rate_limited` are
    # stamped by the AgentLimit gate (Stages::Review's limit arm), never by
    # `classify`; they are listed so this constant is the one authoritative
    # reason list (the wiki points readers here).
    REASONS = %w[
      limits_reached
      rate_limited
      merge_conflict
      network_timeout
      tool_permission_denied
      agent_crashed
      unknown
    ].freeze

    # The subset of REASONS that `classify` can actually emit (in addition to
    # the always-available `unknown` fallback). Must stay in lockstep with
    # PATTERNS.map(&:first) — the closure test guards against drift.
    CLASSIFIED = %w[
      merge_conflict
      network_timeout
      tool_permission_denied
      agent_crashed
    ].freeze

    # The regex tables driving `classify`: ordered [reason, [regexes...]] rows.
    # Order is priority — the first reason with any line-level match wins.
    PATTERNS = [
      [
        "merge_conflict",
        [
          /conflict \(content\)/i,
          /merge conflict in /i,
          /automatic merge failed/i,
          /needs merge/i,
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
          /panic:/i,
          /fatal error:/i,
          /uncaught exception/i,
          /traceback \(most recent call last\)/i,
          /\bkilled\b/i,
          /core dumped/i,
          /\bsigkill\b/i
        ]
      ]
    ].freeze

    module_function

    # Classify only residual, non-limit triage/fix agent failures. Provider
    # quota/rate walls are handled by AgentLimit first so they keep the
    # cooldown-based auto-heal path.
    def classify(error_message)
      text = Hive::AgentLimit.normalize(error_message)
      return "unknown" if text.strip.empty?

      lines = text.each_line.map(&:strip).reject(&:empty?)
      PATTERNS.each do |reason, regexes|
        return reason if lines.any? { |line| regexes.any? { |regex| line.match?(regex) } }
      end

      "unknown"
    end
  end
end
