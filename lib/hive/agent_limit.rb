require "date"
require "time"

module Hive
  module AgentLimit
    # How long to wait, after a `limits_reached` marker is written, before
    # the daemon healer is allowed to auto-retry the parked task. A usage /
    # credit window may have changed by then, so the daemon submits the marker
    # to the shared recovery coordinator. Provider reset
    # hints remain useful for display, but never gate daemon scheduling: credits
    # can be added, usage can be reset, or the active account can change early.
    # Overridable per-process via HIVE_LIMITS_RETRY_COOLDOWN_SEC (a positive
    # integer of seconds); a missing / unparseable / non-positive value falls
    # back to the default so a typo can never silently disable the cooldown.
    RETRY_COOLDOWN_SEC = 3600
    RETRY_COOLDOWN_ENV = "HIVE_LIMITS_RETRY_COOLDOWN_SEC".freeze
    RESET_HINT_GRACE_SEC = 60
    MAX_RESET_HINT_SEC = 366 * 24 * 60 * 60
    RESET_HINT_RE = %r{
      \b(?:try\s+again|available\s+again|resets?|reset)\s+(?:at|on)\s+
      (?<stamp>
        [a-z]{3,9}\s+\d{1,2}(?:st|nd|rd|th)?,\s+\d{4}\s+
        (?:at\s+)?(?<hour>\d{1,2}):(?<minute>\d{2})\s*(?:a\.?m\.?|p\.?m\.?)
      )
      (?<zone>\s*(?:\([^)]+\)|[a-z][a-z0-9_+:/-]*))?
      (?=\s*(?:[.!?,;]|\z))
    }ix.freeze

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

    LIVE_LIMIT_TAIL_LINES = 8
    LIVE_MENU_TAIL_LINES = 4
    LIVE_MENU_PROMPT_LINE = /\A(?:│\s*)?what do you want to do\?/i.freeze
    LIVE_MENU_OPTION_LINE = /\A\s*(?:│\s*)?❯\s*\d+\./.freeze
    LIVE_MENU_BOX_LINE = /\A[╭╰╮╯│][╭╰╮╯│─\s]*\z/.freeze
    # Keep a local copy instead of depending on ClaudeLauncher: AgentLimit owns
    # live-wall classification, and Claude Code prompt chrome is version-coupled.
    LIVE_READY_PROMPT_LINE = /\A❯(?:\s|\z)|\s❯(?:\s*(?:[●✻✢✽✶]|·|\/).*)?\z/.freeze
    LIVE_ACTIVITY_LINE = /[●✻✢✽✶]\s*(?:high|medium|low|thinking|working|esc|\/)/i.freeze
    OWN_ERROR_MESSAGE_RE = /\Alimits reached( for [a-z0-9_-]+)?(:|\z)/.freeze

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
        limit_line?(line)
      end
    end

    def live_limit_menu?(pane)
      !!live_limit_line(pane)
    end

    def live_limit_line(pane)
      live_limit_match(pane)&.first
    end

    # Return only the live provider wall and its adjacent menu/reset lines.
    # Passing the whole pane to retry parsing would let unrelated dated prose
    # elsewhere in an agent transcript forge a much longer quota hold.
    def live_limit_context(pane)
      match = live_limit_match(pane)
      return nil unless match

      _line, source_index, indexed_lines = match
      indexed_lines
        .drop_while { |_candidate, index| index < source_index }
        .first(LIVE_MENU_TAIL_LINES + 1)
        .map(&:first)
        .join("\n")
    end

    def live_limit_match(pane)
      indexed_lines = normalized_non_empty_lines(pane)
      return nil if indexed_lines.empty?

      bottom_lines = indexed_lines.last(LIVE_MENU_TAIL_LINES).map(&:first)
      return nil unless bottom_lines.any? { |line| live_menu_signal_line?(line) }

      indexed_lines.last(LIVE_LIMIT_TAIL_LINES).each do |line, index|
        next unless limit_line?(line)
        next if ready_or_activity_below?(indexed_lines, index)

        return [ line, index, indexed_lines ]
      end

      nil
    end

    def from_limit?(text)
      normalize(text).each_line.any? do |line|
        line.strip.match?(OWN_ERROR_MESSAGE_RE)
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

    # Provider reset estimate shown to operators. Prefer a complete provider
    # date when present; otherwise show `now` plus the fixed cooldown. This is
    # deliberately not the daemon scheduling boundary; `retry_due?` uses the
    # quota marker's mtime so an account switch or top-up is noticed hourly.
    def retry_after(text: nil, now: Time.now.utc)
      retry_after_time_for(text, now: now).iso8601
    end

    # Multiple reviewers can fail against different providers/windows in one
    # pass. Display the latest provider estimate; scheduling remains hourly.
    def retry_after_for(texts, now: Time.now.utc)
      candidates = Array(texts).map { |text| retry_after_time_for(text, now: now) }
      (candidates.max || retry_after_time_for(nil, now: now)).iso8601
    end

    # True when the daemon may make a real readiness attempt for a parked
    # provider-limit task. The latest quota marker is the schedule: each failed
    # attempt writes a fresh marker, while a successful/account-switched attempt
    # stops producing one. Provider reset text is intentionally absent here.
    def retry_due?(limited_at:, now: Time.now.utc)
      limited_at.is_a?(Time) && now >= limited_at + retry_cooldown_sec
    end

    def retry_after_time_for(text, now:)
      explicit = explicit_retry_after(text, now: now)
      return explicit if explicit

      now.utc + retry_cooldown_sec
    end

    # The `held_*` family below is the shared rendering layer over a
    # `reason="limits_reached"` marker (written by 4-execute / 6-review when
    # a provider quota wall is detected) — text status, JSON status, and the
    # TUI all route through these so they can never diverge on the hold
    # label. `held?` recognises ONLY the `:error` / `:review_error` markers
    # that carry the limit reason; any other marker name (or a non-limit
    # reason like `implementer_failed`) is not a quota hold.
    def held?(marker_name, attrs)
      %w[error review_error].include?(marker_name.to_s) &&
        attr_value(attrs, "reason") == "limits_reached"
    end

    # Prefer the explicit `provider=` attr (4-execute always stamps it). The
    # message-based fallback re-parses the `for <provider>:` token that
    # `error_message` (above) bakes into its wire format, and exists ONLY for
    # legacy agent/launcher markers that predate the `provider=` attr; it is
    # display/JSON-only, so a wrong token from an incidental "for <word>:"
    # phrase is cosmetic, never a control-flow decision.
    def held_provider(attrs)
      provider = safe_provider(attr_value(attrs, "provider"))
      return provider if provider

      message = attr_value(attrs, "message")
      match = message.match(/\bfor\s+([a-z0-9_-]+):/i)
      safe_provider(match[1]) if match
    end

    # Human-facing retry time, or nil when the marker has no/garbled
    # `retry_after` (retry_after_time tolerates both).
    def held_retry_display(attrs)
      retry_after_time(attrs)&.strftime("%Y-%m-%d %H:%M UTC")
    end

    # Single-line operator label. Provider reset estimates remain visible, but
    # the periodic retry policy is explicit so the date is not mistaken for a
    # hard scheduling embargo.
    def held_label(attrs)
      label = "held: agent quota"
      provider = held_provider(attrs)
      label = "#{label} (#{provider})" if provider

      retry_display = held_retry_display(attrs)
      label = "#{label} — reset estimate #{retry_display}" if retry_display

      "#{label}; Hive retries #{retry_interval_label}; top up or switch execute agent"
    end

    def retry_interval_label
      seconds = retry_cooldown_sec
      return "hourly" if seconds == 3600
      return "every #{seconds / 3600} hours" if (seconds % 3600).zero?
      return "every #{seconds / 60} minutes" if (seconds % 60).zero?

      "every #{seconds} seconds"
    end

    # Machine-readable `held` object for the JSON status payload (schema:
    # hive-status.v4.json#held). The vocabulary switch is deliberate: the
    # on-disk marker uses `reason="limits_reached"`, but the JSON contract
    # exposes the held state as `reason="quota"` so consumers key off a
    # stable noun rather than the internal marker verb. `provider` /
    # `retry_after` are nullable here precisely because legacy / attr-less
    # markers can omit them. Frozen to match the codebase's immutable-payload
    # convention (Snapshot Rows/ProjectViews) — it is only read/serialized.
    def held_field(attrs)
      {
        "reason" => "quota",
        "provider" => held_provider(attrs),
        "retry_after" => retry_after_time(attrs)&.iso8601
      }.freeze
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

    def normalized_non_empty_lines(text)
      normalize(text).each_line.with_index.filter_map do |line, index|
        stripped = line.strip
        [ stripped, index ] unless stripped.empty?
      end
    end

    def limit_line?(line)
      stripped = line.to_s.strip
      return false if stripped.empty?
      return false if BENIGN_PATTERNS.any? { |pattern| stripped.match?(pattern) }

      LIMIT_PATTERNS.any? { |pattern| stripped.match?(pattern) }
    end

    def live_menu_signal_line?(line)
      stripped = line.to_s.strip
      LIVE_MENU_PROMPT_LINE.match?(stripped) ||
        LIVE_MENU_OPTION_LINE.match?(stripped) ||
        LIVE_MENU_BOX_LINE.match?(stripped)
    end

    def ready_or_activity_below?(indexed_lines, source_index)
      indexed_lines.any? do |line, index|
        index > source_index &&
          ((LIVE_READY_PROMPT_LINE.match?(line) && !LIVE_MENU_OPTION_LINE.match?(line)) ||
           LIVE_ACTIVITY_LINE.match?(line))
      end
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

    def explicit_retry_after(text, now:)
      match = normalize(text).match(RESET_HINT_RE)
      return nil unless match
      return nil unless (1..12).cover?(match[:hour].to_i) && (0..59).cover?(match[:minute].to_i)

      stamp = match[:stamp]
      zone = match[:zone].to_s.strip.delete_prefix("(").delete_suffix(")")
      utc_zone = %w[UTC GMT Z].any? { |name| zone.casecmp?(name) }
      return nil unless zone.empty? || utc_zone

      parts = Date._parse(stamp, false)
      required = %i[year mon mday hour min]
      return nil unless required.all? { |key| parts.key?(key) }
      return nil unless Date.valid_date?(parts[:year], parts[:mon], parts[:mday])
      return nil unless (0..23).cover?(parts[:hour]) && (0..59).cover?(parts[:min])

      values = required.map { |key| parts.fetch(key) }
      parsed = if utc_zone
                 Time.utc(*values)
      else
                 Time.local(*values)
      end
      parsed = parsed.utc + RESET_HINT_GRACE_SEC
      delta = parsed - now.utc
      return nil unless delta.positive? && delta <= MAX_RESET_HINT_SEC

      parsed
    rescue ArgumentError
      nil
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
