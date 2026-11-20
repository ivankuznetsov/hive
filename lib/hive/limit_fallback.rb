require "time"
require "hive/agent_limit"
require "hive/attempts/context"

module Hive
  # Shared decision rules for Hive's opt-in provider-limit fallbacks. Each
  # consumer owns one config block with the same closed shape:
  #
  #   <block>:
  #     limit_fallback:
  #       enabled: true
  #       min_wait_sec: 3600
  #       agents:
  #         codex: claude      # primary profile => fallback profile
  #
  # `review.limit_fallback` (Hive::Stages::Review::LimitFallback) covers the
  # 6-review roles; `implementation.limit_fallback`
  # (Hive::ImplementationLimitFallback) covers execute, open_pr, artifacts
  # and finalize. A substitution is approved only when every condition holds:
  #   - the block is enabled and maps the primary profile to a different one;
  #   - the primary failed with a classified provider limit (the same signal
  #     that produces `reason=limits_reached`); generic failures,
  #     auth/preflight errors and refused models never fall back;
  #   - the provider's explicit reset hint is absent or at least
  #     `min_wait_sec` away (a short wall is better waited out);
  #   - the durable attempt is not under explicit provider-account routing,
  #     whose router already owns adapter selection.
  module LimitFallback
    DEFAULT_MIN_WAIT_SEC = 3600
    LIMIT_DETAIL_MAX = 200

    # One approved substitution. `phase` is the consumer's phase or stage;
    # `role` is its display name. `retry_after` is the provider's explicit
    # reset estimate (ISO-8601), or nil when the provider gave none.
    Decision = Data.define(:phase, :role, :primary, :fallback, :retry_after, :limit_detail)

    # A classified limit that a configured fallback deliberately did not
    # substitute because the provider resets sooner than `min_wait_sec`.
    Deferral = Data.define(:phase, :role, :primary, :fallback, :retry_after, :limit_detail)

    module_function

    # The settings hash at `path` when it is enabled, else nil.
    def settings(cfg, path)
      raw = cfg.is_a?(Hash) ? cfg.dig(*path) : nil
      return nil unless raw.is_a?(Hash) && raw["enabled"] == true

      raw
    end

    # Fallback profile configured at `path` for `primary`, or nil.
    def configured_fallback(cfg, path, primary)
      opts = settings(cfg, path)
      return nil unless opts && primary

      agents = opts["agents"]
      return nil unless agents.is_a?(Hash)

      fallback = agents[primary.to_s].to_s.strip
      return nil if fallback.empty? || fallback == primary.to_s

      fallback
    end

    def limited?(limit_text:, error_message:)
      !limit_text.to_s.empty? || Hive::AgentLimit.from_limit?(error_message.to_s)
    end

    # Classify one failed primary run. Returns a Decision (substitute now),
    # a Deferral (a mapped fallback exists but the reset is too close), or
    # nil (not applicable). Every refusal after a classified limit on an
    # enabled config goes through `log` so an operator can see why no
    # substitute ran.
    def evaluate(cfg, path:, phase:, primary:, limit_text:, error_message:, log:,
                 role: phase, now: Time.now.utc)
      opts = settings(cfg, path)
      return nil unless opts
      return nil unless limited?(limit_text: limit_text, error_message: error_message)

      text = limit_text.to_s.empty? ? error_message.to_s : limit_text.to_s
      primary = primary.to_s
      fallback = configured_fallback(cfg, path, primary)
      unless fallback
        log.call("#{role}: #{primary.inspect} hit a usage/credit limit; no fallback agent configured " \
                 "for it in #{path.join('.')}.agents")
        return nil
      end
      if Hive::Attempts::Context.current&.explicit_routing?
        log.call("#{role}: #{primary} hit a usage/credit limit; fallback to #{fallback} skipped " \
                 "because this attempt uses explicit provider routing")
        return nil
      end

      explicit = Hive::AgentLimit.explicit_retry_after(text, now: now)
      facts = {
        phase: phase.to_s, role: role.to_s, primary: primary, fallback: fallback,
        retry_after: explicit&.iso8601,
        limit_detail: Hive::AgentLimit.first_useful_line(text)[0, LIMIT_DETAIL_MAX]
      }
      min_wait = min_wait_sec(opts)
      if explicit && (explicit - now) < min_wait
        log.call("#{role}: #{primary} hit a usage/credit limit resetting at #{explicit.iso8601} " \
                 "(< min_wait_sec=#{min_wait}); waiting for reset instead of falling back to #{fallback}")
        return Deferral.new(**facts)
      end

      Decision.new(**facts)
    end

    # The approved Decision from `evaluate`, or nil.
    def decide(cfg, **options)
      verdict = evaluate(cfg, **options)
      verdict if verdict.is_a?(Decision)
    end

    # Outcome for a finished substitute run: "used" when it succeeded,
    # "limited" when it also hit a limit, else "failed".
    def outcome(ok:, limit_text:, error_message:)
      return "used" if ok

      limited?(limit_text: limit_text, error_message: error_message) ? "limited" : "failed"
    end

    def min_wait_sec(opts)
      value = opts["min_wait_sec"]
      value.is_a?(Integer) && value >= 0 ? value : DEFAULT_MIN_WAIT_SEC
    end
  end
end
