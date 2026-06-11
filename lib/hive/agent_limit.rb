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

    # Lines that merely MENTION limits without being a wall. Claude Code's
    # chrome (banner, footer, hint bar) carries informational copy that
    # changes between releases — e.g. the plan-inclusion promo "Included in
    # your plan limits until Jun 22, then switch to usage credits to
    # continue.", or hints like "/status to see usage limits". These lines
    # persist in the pane for the WHOLE session, so matching them does not
    # just break launches — it kills healthy mid-run sessions. They are
    # filtered out line-by-line BEFORE the limit patterns run.
    BENIGN_PATTERNS = [
      /included in your plan/i,
      /plan limits? until/i,
      /to see usage limits?/i,
      /usage limits? (?:reset|renew)s? (?:on|at|in)/i,
      # Box-drawing / chrome-only lines can never be a limit sentence.
      /\A[\s╭╮╰╯─│▐▛▜▝▘▎●❯>·]+\z/
    ].freeze

    LIMIT_PATTERNS = [
      /stop and wait for limit to reset/i,
      /add funds to continue with usage credits/i,
      /switch to team plan/i,
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

    # Line-based with a benign filter, and biased toward false NEGATIVES:
    # a missed wall degrades to a clean timeout marker the healer retries,
    # while a false positive kills healthy sessions on every surface (the
    # plan-inclusion banner did exactly that). Provider chrome copy changes
    # without notice — never classify on text that can sit in a healthy
    # pane; see BENIGN_PATTERNS and the launcher's readiness-wins ordering.
    def limit_reached?(text)
      normalized = normalize(text)
      return false if normalized.empty?

      normalized.each_line.any? do |line|
        stripped = line.strip
        next false if stripped.empty?
        next false if BENIGN_PATTERNS.any? { |pattern| stripped.match?(pattern) }

        LIMIT_PATTERNS.any? { |pattern| stripped.match?(pattern) }
      end
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
