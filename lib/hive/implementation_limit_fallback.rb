require "time"
require "hive/agent_profiles"
require "hive/attempts/context"
require "hive/implementation_identity/store"
require "hive/limit_fallback"

module Hive
  # Opt-in substitution of an implementation stage's agent when its primary
  # provider hits a classified usage/credit limit.
  #
  # Configured by `implementation.limit_fallback`, with the same shape,
  # defaults and safety rules as `review.limit_fallback` (Hive::LimitFallback):
  #
  #   implementation:
  #     limit_fallback:
  #       enabled: true
  #       min_wait_sec: 3600
  #       agents:
  #         codex: grok
  #
  # Covered launches: the execute implementer, the open-PR author, the
  # artifacts inference and reviewer roles, and the finalize agent. The
  # 6-review roles, including the review.fix / review.ci implementation
  # stages, keep using `review.limit_fallback`.
  #
  # Execute and open_pr launch a pinned implementation identity. A
  # substitution never rewrites that pin. It holds for the attempt that made
  # it only: a retry, or a later stage resolving from the execute pin, starts
  # on the primary again and re-evaluates its limit. While the primary stays
  # limited, every attempt spends one limited launch before substituting.
  #
  # The substitute's model is the one the stage's own config names for it
  # when that config names the fallback agent (an operator reroute), else the
  # fallback profile's default model. The primary's model pins and
  # `models:` routes never reach it.
  #
  # Every approved substitution is journaled as
  # `implementation_identity_substituted` (stage, role, primary and
  # substitute identity, limit line, explicit reset) before the substitute
  # launches. A substitute that is also limited, or fails, leaves the
  # primary's `limits_reached` marker in place annotated with
  # `primary_agent` / `fallback_agent` / `fallback_outcome`; a reset that is
  # too close is annotated `fallback_outcome=waiting`.
  module ImplementationLimitFallback
    CONFIG_PATH = %w[implementation limit_fallback].freeze
    STAGES = %w[execute open_pr artifacts finalize].freeze
    IDENTITY_STAGES = %w[execute open_pr].freeze

    # The evaluated fallback for one limited primary launch. `state` is
    # "substitute" (launch `fallback` once; `identity` is its Selection on
    # identity stages), "waiting" (the provider resets sooner than
    # `min_wait_sec`), or "unresolved" (the substitute identity could not be
    # resolved, so the primary's limit stands).
    Plan = Data.define(:stage, :role, :primary, :fallback, :state, :retry_after, :limit_detail, :identity) do
      def substitute? = state == "substitute"

      def log_label(base) = "#{base}-fallback-#{fallback}"

      def marker_attrs(outcome = state)
        { primary_agent: primary, fallback_agent: fallback, fallback_outcome: outcome.to_s }
      end
    end

    module_function

    def settings(cfg)
      Hive::LimitFallback.settings(cfg, CONFIG_PATH)
    end

    def configured_fallback(cfg, primary)
      Hive::LimitFallback.configured_fallback(cfg, CONFIG_PATH, primary)
    end

    # Evaluate a primary launch the stage already classified as
    # `limits_reached`. Returns a Plan, or nil when the option is off, the
    # primary has no mapping, or the attempt uses explicit provider routing.
    # `limit_text` carries the stage's limit signal (raw limit text, or the
    # error message that classified it).
    def plan(cfg:, stage:, primary:, limit_text:, error_message: nil, role: stage,
             execute_identity: nil, now: Time.now.utc)
      stage = stage.to_s
      raise ArgumentError, "#{stage.inspect} is not an implementation-limit-fallback stage" unless STAGES.include?(stage)
      return nil unless settings(cfg)

      verdict = Hive::LimitFallback.evaluate(
        cfg, path: CONFIG_PATH, phase: stage, role: role, primary: primary,
        limit_text: limit_text, error_message: error_message, now: now,
        log: method(:log)
      )
      return nil unless verdict

      facts = {
        stage: stage, role: role.to_s, primary: verdict.primary, fallback: verdict.fallback,
        retry_after: verdict.retry_after, limit_detail: verdict.limit_detail
      }
      return Plan.new(**facts, state: "waiting", identity: nil) if verdict.is_a?(Hive::LimitFallback::Deferral)

      begin
        identity = resolve_identity(cfg, stage, verdict.fallback, execute_identity) if IDENTITY_STAGES.include?(stage)
      rescue Hive::ImplementationIdentity::Error, Hive::ConfigError => e
        log("#{role}: #{verdict.primary} hit a usage/credit limit, but fallback #{verdict.fallback} " \
            "could not be resolved (#{e.message}); keeping #{verdict.primary}'s limit")
        return Plan.new(**facts, state: "unresolved", identity: nil)
      end
      Plan.new(**facts, state: "substitute", identity: identity)
    end

    # The substitute's durable launch identity for execute/open_pr. Runs
    # without a durable attempt too (direct stage runs), so generation falls
    # back to the execute pin's or 0; nothing is journaled then.
    def resolve_identity(cfg, stage, fallback, execute_identity)
      context = Hive::Attempts::Context.current
      generation = context&.task_generation || identity_generation(execute_identity) || 0
      Hive::ImplementationIdentity::Resolver.new(cfg: cfg).resolve_limit_fallback(
        stage, provider: fallback, execute_identity: execute_identity,
        generation: generation, attempt_id: context&.attempt_id
      )
    end

    # The execute identity pinned for the current generation, read without
    # appending anything, or nil outside a durable attempt.
    def current_execute_identity(task, cfg)
      return nil unless Hive::Attempts::Context.current

      Hive::ImplementationIdentity::Store.new(task: task, cfg: cfg).current_execute
    end

    # Journal an approved substitution before the substitute launches.
    # `primary` and `substitute` are a Selection or a route Hash
    # ({"provider", "model"}). Returns true when recorded (or when there is
    # no durable attempt to record against). A failed append is logged and
    # returns false: the caller then keeps the primary's limit instead of
    # launching an unrecorded substitute.
    def record!(task:, cfg:, plan:, primary:, substitute: plan.identity)
      return true unless Hive::Attempts::Context.current

      Hive::ImplementationIdentity::Store.new(task: task, cfg: cfg).record_limit_fallback!(
        stage: plan.stage, role: plan.role,
        primary: primary || { "provider" => plan.primary },
        substitute: substitute || { "provider" => plan.fallback },
        retry_after: plan.retry_after, limit_detail: plan.limit_detail
      )
      true
    rescue Hive::Error, SystemCallError => e
      log("#{plan.role}: could not journal the #{plan.fallback} substitution for #{plan.primary} " \
          "(#{e.class}: #{e.message}); keeping #{plan.primary}'s limit")
      false
    end

    # Outcome of a finished substitute run, logged with the plan's facts:
    # "used", "limited" (the substitute also hit a limit), or "failed".
    def finish(plan, ok:, limited:)
      outcome = if ok
        "used"
      else
        limited ? "limited" : "failed"
      end
      log("#{plan.role}: #{plan.primary} hit a usage/credit limit (#{plan.limit_detail}; " \
          "retry_after=#{plan.retry_after || 'unknown'}); fallback #{plan.fallback} #{outcome} " \
          "for this attempt; the #{plan.primary} pin is unchanged")
      outcome
    end

    # Config handed to a substitute launch whose stage config does not name
    # the fallback: the primary's provider-neutral `models:` routes are
    # withheld so the fallback profile's own default model applies.
    def fallback_cfg(cfg)
      return cfg unless cfg.is_a?(Hash) && cfg.key?("models")

      cfg.reject { |key, _| key == "models" }
    end

    def identity_generation(identity)
      return nil unless identity
      return identity.generation if identity.respond_to?(:generation)

      identity["generation"] || identity[:generation]
    end

    def log(message)
      warn "[hive.implementation] limit fallback: #{message}"
    end
  end
end
