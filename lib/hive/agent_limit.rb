require "time"

module Hive
  module AgentLimit
    # How long to wait, after a `limits_reached` marker is written, before
    # the daemon healer is allowed to auto-retry the parked task. A usage /
    # credit window has plausibly reset by then, so the marker self-heals
    # instead of staying red until a human runs `hive markers clear`. A
    # fixed cooldown is the robust default — we deliberately do NOT parse the
    # provider's "try again at 4:42 PM" wall-clock hint (a future enhancement).
    # Overridable per-process via HIVE_LIMITS_RETRY_COOLDOWN_SEC (a positive
    # integer of seconds); a missing / unparseable / non-positive value falls
    # back to the default so a typo can never silently disable the cooldown.
    RETRY_COOLDOWN_SEC = 3600
    RETRY_COOLDOWN_ENV = "HIVE_LIMITS_RETRY_COOLDOWN_SEC".freeze

    LIMIT_PATTERNS = [
      /stop and wait for limit to reset/i,
      /add funds to continue with usage credits/i,
      /switch to team plan/i,
      # Deliberately NOT a bare /usage credits/i: Claude Code's startup
      # banner shows an informational "Included in your plan limits until
      # <date>, then switch to usage credits to continue." promo line to
      # every subscriber — a bare match classified EVERY healthy launch as
      # limits_reached. Genuine walls phrase an action or exhaustion around
      # the words, covered by the patterns above and below.
      /(?:out of|no remaining|purchase(?:\s+more)?) usage credits/i,
      /insufficient[_\s-]*quota/i,
      /quota (?:exhausted|exceeded|reached)/i,
      /rate limit (?:reached|exceeded|reset|hit)/i,
      /rate limited/i,
      /too many requests/i,
      /\b(?:http|status|response)[:=\s-]*429\b/i,
      /\b429\b[^\n]{0,40}(?:too many|rate limit|quota|requests)/i,
      /resource[_\s-]*exhausted/i,
      /limit (?:reached|exceeded|reset)/i,
      /(?:daily|monthly|usage|spend|spending) limit/i,
      /billing[^\n]{0,80}(?:credit|quota|limit)/i
    ].freeze

    module_function

    def limit_reached?(text)
      normalized = normalize(text)
      return false if normalized.empty?

      LIMIT_PATTERNS.any? { |pattern| normalized.match?(pattern) }
    end

    def error_message(text, agent: nil)
      prefix = "limits reached"
      prefix = "#{prefix} for #{agent}" if agent && !agent.to_s.empty?
      detail = first_useful_line(text)
      detail.empty? ? prefix : "#{prefix}: #{detail}"
    end

    # Cooldown window in seconds, after env override (see RETRY_COOLDOWN_SEC).
    def retry_cooldown_sec
      raw = ENV[RETRY_COOLDOWN_ENV]
      parsed = Integer(raw, exception: false) if raw
      parsed&.positive? ? parsed : RETRY_COOLDOWN_SEC
    end

    # ISO8601 timestamp the daemon healer may retry a `limits_reached` task
    # at: `now` (UTC) plus the cooldown window. Stamped into the marker at
    # write time so the comparison is a pure on-disk read at heal time.
    def retry_after(now: Time.now.utc)
      (now.utc + retry_cooldown_sec).iso8601
    end

    def first_useful_line(text)
      normalize(text).each_line.map(&:strip).find { |line| !line.empty? }.to_s
    end

    def normalize(text)
      text.to_s
          .scrub
          .gsub(/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
          .gsub(/[[:cntrl:]&&[^\n\t]]/, "")
    end
  end
end
