# frozen_string_literal: true

module HiveBench
  # A provider/transport layer raises this only from trusted quota evidence.
  # Judge/model output must never manufacture an automatic-retry decision.
  class ProviderLimitError < StandardError
    def initialize(message)
      super("limits_reached: #{message}")
    end
  end

  # Detects when a candidate run hit a provider usage/credit/rate limit rather
  # than genuinely failing. A limit is not a clean exit code — it surfaces as a
  # message in the agent's stream ("you've hit your usage limit", a 429, quota
  # text). Mirrors hive's Hive::AgentLimit learning: a limit-hit cell must be
  # marked **re-run later**, never scored 0, or the leaderboard punishes an
  # agent for the maintainer's billing window.
  #
  # Biased toward false negatives: a missed limit degrades to an ordinary failed
  # cell (re-run anyway); a false positive would wrongly excuse a real failure,
  # so benign "limit" chrome is filtered first.
  module AgentLimit
    module_function

    BENIGN = [
      /included in your plan/i,
      /to see usage limits?/i,
      /usage limits? (?:reset|renew)s? (?:on|at|in)/i,
      /approaching[^\n]{0,40}(?:session|usage) limit/i
    ].freeze

    LIMIT = [
      # Claude Code 2.1.220 emits a structured event rather than quota prose
      # when a request is rejected at the account window. Require both the
      # event type and rejected status so informational rate-limit events do
      # not park healthy cells.
      /"type"\s*:\s*"rate_limit_event"[^\n]*"status"\s*:\s*"rejected"/i,
      /(?:hit|reached) your (?:usage|session) limit/i,
      /stop and wait for limit to reset/i,
      /(?:out of|no remaining|purchase(?:\s+more)?) usage credits/i,
      /insufficient[_\s-]*quota/i,
      # OpenRouter (and other pay-per-token providers Pi fronts) return a 402 with
      # "Insufficient credits" on an empty balance, or a 403 "Key limit exceeded"
      # once a key hits its spend cap. Without these, a credit/key-drained
      # open-model cell is misscored as a real failure instead of parked pending.
      /insufficient (?:credits?|balance|funds)/i,
      # OpenRouter's other empty-balance phrasing: "This request requires more
      # credits, or fewer max_tokens" — without it, a drained-balance judge
      # failure parks the cell as failed instead of pending (seen live 2026-07-06).
      /requires more credits/i,
      /\b402\b[^\n]{0,40}(?:credit|payment|insufficient)/i,
      /(?:key|credit|spend(?:ing)?|usage|total|monthly|daily) limit exceeded/i,
      /\b403\b[^\n]{0,40}limit exceeded/i,
      # hive's own stage-error marker for a provider wall mid-stage:
      #   `stage recorded :error ({"reason" => "limits_reached", ...})`
      #   `implementer hit a usage/credit limit`
      /limits_reached/i,
      %r{hit a usage/credit limit}i,
      /quota (?:exhausted|exceeded|reached)/i,
      /rate limit (?:reached|exceeded|reset|hit)/i,
      /too many requests/i,
      /\b(?:http|status|response)[:=\s-]*429\b/i,
      /resource[_\s-]*exhausted/i
    ].freeze

    # True if any non-benign line matches a limit pattern.
    def limit_hit?(text)
      normalize(text).each_line.any? do |line|
        stripped = line.strip
        next false if stripped.empty?
        next false if BENIGN.any? { |re| stripped.match?(re) }

        LIMIT.any? { |re| stripped.match?(re) }
      end
    end

    def normalize(text)
      text.to_s.scrub.gsub(%r{\e\[[0-9;?]*[ -/]*[@-~]}, "")
    end
  end
end
