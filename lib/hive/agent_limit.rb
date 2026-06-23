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
      # "Approaching session limit" sits in a HEALTHY pane as a warning;
      # only the past-tense wall ("hit your session limit") is terminal.
      /approaching[^\n]{0,40}session limit/i,
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
      # Claude subscription wall: "You've hit your session limit · resets
      # 8pm (Europe/London)". Verb-anchored so the healthy-pane warning
      # "Approaching session limit" can never match.
      /(?:hit|reached) your session limit/i,
      /rate limited/i,
      /too many requests/i,
      /\b(?:http|status|response)[:=\s-]*429\b/i,
      /\b429\b[^\n]{0,40}(?:too many|rate limit|quota|requests)/i,
      /resource[_\s-]*exhausted/i,
      # Was a bare `/limit (?:reached|exceeded|reset)/i`, which matched ANY
      # "<x> limit reached" — including healthy agent OUTPUT. A finalize agent
      # describing a scrollable-TUI feature ("scroll limit reached", "window
      # limit") tripped a false `limits_reached` wall (task 47). Require a
      # usage/billing/rate qualifier so only a real provider wall matches; UI
      # limits (scroll/window/viewport/page/buffer/line) no longer do. Honors
      # the file's "never classify on text that can sit in a healthy pane" rule.
      %r{(?:usage|rate|api|token|context|message|request|session|spend|spending|credit|quota|account|subscription|\d+[\s-]?hour|hourly|daily|weekly|monthly)[\s-]?limit (?:reached|exceeded|reset)}i,
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

    def held?(marker_name, attrs)
      %w[error review_error].include?(marker_name.to_s) &&
        attr_value(attrs, "reason") == "limits_reached"
    end

    def held_provider(attrs)
      provider = safe_provider(attr_value(attrs, "provider"))
      return provider if provider

      message = attr_value(attrs, "message")
      match = message.match(/\bfor\s+([a-z0-9_-]+):/i)
      safe_provider(match[1]) if match
    end

    def held_retry_display(attrs)
      retry_after_time(attrs)&.strftime("%Y-%m-%d %H:%M UTC")
    end

    def held_label(attrs)
      label = "held: agent quota"
      provider = held_provider(attrs)
      label = "#{label} (#{provider})" if provider

      retry_display = held_retry_display(attrs)
      label = "#{label} — retry after #{retry_display}" if retry_display

      "#{label}; top up or switch execute agent"
    end

    def held_field(attrs)
      {
        "reason" => "quota",
        "provider" => held_provider(attrs),
        "retry_after" => retry_after_time(attrs)&.iso8601
      }
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

    def attr_value(attrs, key)
      return "" unless attrs

      attrs[key].to_s
    end

    def safe_provider(value)
      token = value.to_s.strip
      return nil unless token.match?(/\A[a-z0-9_-]+\z/i)

      token
    end

    def retry_after_time(attrs)
      raw = attr_value(attrs, "retry_after")
      return nil if raw.empty?

      Time.parse(raw).utc
    rescue ArgumentError
      nil
    end
  end
end
