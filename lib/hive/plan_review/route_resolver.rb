require "hive/agent_profiles"
require "hive/agent_runtime"
require "hive/model_routing"
require "hive/plan_review"
require "hive/secret_patterns"

module Hive
  module PlanReview
    module RouteResolver
      CANDIDATE_KEYS = %w[provider model family effort route].freeze
      IDENTITY_CONTRACT_VERSION = 1
      ROLE_IDENTITIES = {
        "primary" => "plan_review",
        "adversarial" => "plan_review_adversarial",
        "verification" => "plan_review_verification"
      }.freeze

      Resolution = Data.define(:status, :candidate, :receipt) do
        def resolved? = status == "resolved"
      end

      module_function

      def resolve(role:, planner_identity:, candidates: nil, cfg: nil, probe: method(:default_probe))
        role = role.to_s
        candidates = Array(candidates || configured_candidates(role, cfg)).map do |candidate|
          normalize_candidate(candidate, require_family: false)
        end
        raise Hive::ConfigError, "plan review route requires at least one candidate" if candidates.empty?

        attempts = []
        first_present = nil
        candidates.each do |candidate|
          observation = normalize_hash(probe.call(candidate))
          status = observation.fetch("status", "unsupported")
          attempts << {
            "candidate" => candidate,
            "status" => status,
            "diagnostic" => redact(observation["diagnostic"])
          }.compact
          next unless status == "present"

          actual = normalize_observed_identity(observation["actual"])
          verified, reason = independence(planner_identity, actual)
          if verified
            return resolved(
              role:, requested: candidates.first, candidate:, actual:,
              verified:, reason:, attempts:
            )
          end

          first_present ||= { candidate:, actual:, verified:, reason: }
        end

        if first_present
          return resolved(
            role:, requested: candidates.first, attempts:,
            **first_present
          )
        end

        last = attempts.last || {}
        Resolution.new(
          status: "unsupported",
          candidate: nil,
          receipt: {
            "role" => role,
            "requested" => candidates.first,
            "actual" => {},
            "capability_result" => last.fetch("status", "unsupported"),
            "independence_verified" => false,
            "independence_reason" => "reviewer_family_unavailable",
            "attempts" => immutable_attempts(attempts)
          }.freeze
        ).freeze
      end

      def default_candidates(role)
        case role.to_s
        when "adversarial"
          [
            {
              "provider" => "grok", "model" => "grok-4.6", "family" => "grok",
              "effort" => "high", "route" => "native_grok_build"
            }
          ]
        when "verification"
          [
            {
              "provider" => "codex", "model" => "gpt-5.6-sol", "family" => "openai",
              "effort" => "high", "route" => "native_codex"
            }
          ]
        else
          [
            {
              "provider" => "codex", "model" => "gpt-5.6-sol", "family" => "openai",
              "effort" => "high", "route" => "native_codex"
            }
          ]
        end
      end

      def immutable_attempts(attempts)
        attempts.map { |attempt| attempt.dup.freeze }.freeze
      end
      private_class_method :immutable_attempts

      def resolved(role:, requested:, candidate:, actual:, verified:, reason:, attempts:)
        Resolution.new(
          status: "resolved", candidate: candidate.freeze,
          receipt: {
            "role" => role, "requested" => requested, "actual" => actual,
            "capability_result" => "present",
            "independence_verified" => verified,
            "independence_reason" => reason,
            "attempts" => immutable_attempts(attempts)
          }.freeze
        ).freeze
      end
      private_class_method :resolved

      def configured_candidates(role, cfg)
        return default_candidates(role) unless cfg.is_a?(Hash) && cfg.dig("plan_review", "routes", role)

        row = cfg.dig("plan_review", "routes", role)
        route_identity = cfg.dig("plan_review", "reviewers", role) || ROLE_IDENTITIES.fetch(role, "plan_review")
        resolution = Hive::ModelRouting.resolve(
          models: cfg.fetch("models", Hive::ModelRouting::EMPTY_MODELS),
          stage: route_identity,
          provider: row.fetch("agent"),
          current: { model: row.fetch("model"), effort: row.fetch("effort") }
        )
        primary = {
          "provider" => row.fetch("agent"),
          "model" => resolution.model || row.fetch("model"),
          "family" => row.fetch("family"),
          "effort" => resolution.effort || row.fetch("effort"),
          "route" => row.fetch("route")
        }
        fallbacks = Array(cfg.dig("plan_review", "routes", "fallbacks")).map do |fallback|
          {
            "provider" => fallback.fetch("agent"),
            "model" => fallback.fetch("model"),
            "family" => fallback.fetch("family"),
            "effort" => fallback.fetch("effort"),
            "route" => fallback.fetch("route")
          }
        end
        [ primary, *fallbacks ]
      end

      # The detached worktree is the common confinement boundary, so the only
      # thing that can refuse a provider here is failing to prepare its runtime
      # at all, and the diagnostic says so.
      def default_probe(candidate)
        profile = Hive::AgentProfiles.lookup(candidate.fetch("provider"))
        result = Hive::AgentRuntime.prepare!(profile)
        {
          "status" => "present",
          # Runtime preparation attests only the launcher/provider. The served
          # model is observed after the call; configured model/family values
          # must not be promoted into the actual identity here.
          "actual" => {
            "provider" => result.provider.to_s,
            "route" => result.launcher_identity.to_s
          }
        }
      rescue StandardError => e
        { "status" => "unsupported", "diagnostic" => e.message }
      end

      def independence(planner_identity, actual)
        planner = normalize_hash(planner_identity || {})["family"].to_s.strip.downcase
        reviewer = actual["family"].to_s.strip.downcase
        return [ false, "planner_family_unknown" ] if planner.empty?
        return [ false, "reviewer_family_unknown" ] if reviewer.empty?
        return [ false, "same_model_family" ] if planner == reviewer

        [ true, "different_model_family" ]
      end

      # A provider may report a served model alias rather than the configured
      # model name. Promote the configured family only when provider support
      # explicitly attests that exact requested/served pair. This keeps the
      # alias rule in one place for new calls and legacy receipt recovery.
      def attest_observed_identity(requested:, actual:)
        requested = normalize_hash(requested)
        actual = normalize_observed_identity(actual)
        return actual if actual["family"]

        provider = actual["provider"].to_s
        requested_model = requested["model"].to_s
        served_model = actual["model"].to_s
        family = requested["family"].to_s
        return actual if provider.empty? || requested_model.empty? || served_model.empty? || family.empty?
        return actual unless provider == requested["provider"].to_s

        support = Hive::AgentSupport.for(provider)
        equivalent = served_model == requested_model ||
                     support&.respond_to?(:model_identity_equivalent?) &&
                       support.model_identity_equivalent?(
                         requested_model:, served_model:, family:
                       )
        equivalent ? actual.merge("family" => redact(family)).freeze : actual
      end

      def recoverable_identity_route(routes:, planner_identity:)
        routes = Array(routes)
        return if routes.any? { |route| current_identity_contract?(route) }

        route = routes.reverse.find { |entry| entry["role"] == "adversarial" }
        return unless route && %w[success partial_coverage].include?(route["outcome"])
        return if route["independence_verified"] == true

        actual = attest_observed_identity(
          requested: route["requested"], actual: route["actual"]
        )
        verified, = independence(planner_identity, actual)
        route if verified
      rescue Hive::ConfigError
        nil
      end

      def current_identity_contract?(route)
        route["identity_contract_recovery"] == true &&
          Integer(route["identity_contract_version"]) >= IDENTITY_CONTRACT_VERSION
      rescue ArgumentError, TypeError
        false
      end
      private_class_method :current_identity_contract?

      def normalize_candidate(value, require_family: true)
        candidate = normalize_hash(value)
        unknown = candidate.keys - CANDIDATE_KEYS
        raise Hive::ConfigError, "plan review route has unknown fields: #{unknown.inspect}" unless unknown.empty?
        %w[provider model effort route].each do |key|
          unless candidate[key].is_a?(String) && !candidate[key].strip.empty?
            raise Hive::ConfigError, "plan review route #{key} must be non-empty"
          end
        end
        if require_family && (!candidate["family"].is_a?(String) || candidate["family"].empty?)
          raise Hive::ConfigError, "plan review route family must be attested"
        end
        candidate["family"] = nil if candidate["family"].to_s.empty?
        candidate.transform_values { |entry| entry.is_a?(String) ? redact(entry) : entry }.freeze
      end

      def normalize_observed_identity(value)
        actual = normalize_hash(value || {}).reject do |_key, entry|
          entry.nil? || (entry.is_a?(String) && entry.strip.empty?)
        end
        unknown = actual.keys - CANDIDATE_KEYS
        raise Hive::ConfigError, "observed plan review route has unknown fields: #{unknown.inspect}" unless unknown.empty?

        actual.each do |key, entry|
          unless entry.is_a?(String) && !entry.strip.empty?
            raise Hive::ConfigError, "observed plan review route #{key} must be non-empty"
          end
        end
        actual.transform_values { |entry| redact(entry) }.freeze
      end

      def normalize_hash(value)
        return {} unless value.respond_to?(:to_h)

        value.to_h { |key, child| [ key.to_s, child ] }
      end

      def redact(value)
        Hive::SecretPatterns.redact(value.to_s)
      end
    end
  end
end
