require "digest"
require "json"
require "time"
require "hive/provider_routing/signal"

module Hive
  module AgentProfiles
    # Adapter-owned interpretation of bounded CLI evidence. Circuit policy sees
    # only the returned Signal; raw output remains in the existing adapter log.
    module ErrorNormalizers
      class Normalizer
        BILLING_CONFIGURATION = /billing (?:account|configuration) not configured|payment method required|billing setup required/i
        AUTH = /invalid[_\s-]*(?:api[_\s-]*)?key|unauthori[sz]ed|authentication failed|not authenticated|login required|expired credential/i
        PERMISSION = /permission denied|access forbidden|forbidden by provider|insufficient permissions?/i
        CONTEXT = /maximum context length|context window (?:exceeded|overflow|too (?:large|long))|prompt is too long|too many tokens for (?:this )?context/i
        SESSION = /(?:hit|reached) your session limit|session[_\s-]*limit[_\s-]*(?:reached|exceeded)|stop and wait for limit to reset/i
        CREDIT = /(?:out of|no remaining|insufficient|exhausted?) (?:usage )?credits?|credit balance (?:exhausted|empty)|purchase more usage credits/i
        QUOTA = /insufficient[_\s-]*quota|quota (?:exhausted|exceeded|reached)|(?:hit (?:your )?|reached |exceeded )usage limit|usage limit (?:reached|exceeded)|resource[_\s-]*exhausted/i
        RATE = /too many requests|rate[_\s-]*limit(?:ed| (?:reached|exceeded|hit))|\b429\b/i
        NETWORK = /connection (?:reset|refused|closed)|network (?:unreachable|error|failure)|dns (?:error|failure)|socket hang up|broken pipe/i
        TIMEOUT = /request timed out|operation timed out|deadline exceeded/i
        EXPLICIT_MODEL_SCOPE = /"model_scope"\s*:\s*true|model-specific|model_scoped/i

        def initialize(adapter)
          @adapter = adapter.to_s
        end

        def call(evidence:, exit_code:, timed_out:, model:, provider:, evidence_ref:, success:)
          return nil if success

          text = bounded(evidence)
          failure_class = classify(text, timed_out: timed_out)
          scope = scope_for(failure_class, text, model)
          ProviderRouting::Signal.new(
            provider: provider.to_s.empty? ? @adapter : provider,
            model: scope == "model" ? model : nil,
            failure_class: failure_class,
            scope: scope,
            reset_at: reset_hint(text),
            safe_summary: summary(failure_class),
            fingerprint: "sha256:#{Digest::SHA256.hexdigest(text)}",
            evidence_ref: evidence_ref
          )
        rescue StandardError
          unknown_signal(provider: provider, evidence: evidence, evidence_ref: evidence_ref)
        end

        private

        def classify(text, timed_out:)
          return "timeout" if timed_out
          return "billing_configuration" if text.match?(BILLING_CONFIGURATION)
          return "auth" if text.match?(AUTH)
          return "permission" if text.match?(PERMISSION)
          return "context_length" if text.match?(CONTEXT)
          return "session_limit" if text.match?(SESSION)
          return "credit" if text.match?(CREDIT) || http_status?(text, 402)
          return "quota" if text.match?(QUOTA)
          return "rate_limit" if text.match?(RATE)
          return "network" if text.match?(NETWORK)
          return "timeout" if text.match?(TIMEOUT)

          "unknown"
        end

        def scope_for(failure_class, text, model)
          return "task" if failure_class == "context_length"
          return "none" unless ProviderRouting::FAILURE_CLASSES.include?(failure_class)
          return "model" if model && text.match?(EXPLICIT_MODEL_SCOPE)

          "provider"
        end

        def reset_hint(text)
          if (match = text.match(/"retry_after"\s*:\s*(\d+)/i))
            return Time.now.utc + match[1].to_i
          end
          if (match = text.match(/retry[-_ ]after[:=\s]+(\d+)\s*(?:s|sec|seconds?)\b/i))
            return Time.now.utc + match[1].to_i
          end
          if (match = text.match(/"(?:reset_at|reset_time)"\s*:\s*"([^"]+)"/i))
            parsed = Time.iso8601(match[1]).utc
            return parsed if parsed > Time.now.utc
          end
          nil
        rescue ArgumentError
          nil
        end

        def summary(failure_class)
          noun = {
            "session_limit" => "session limit",
            "rate_limit" => "rate limit",
            "context_length" => "context length mismatch",
            "billing_configuration" => "billing configuration failure",
            "auth" => "authentication failure",
            "permission" => "permission failure",
            "credit" => "credit exhausted",
            "quota" => "quota exhausted",
            "network" => "network failure",
            "timeout" => "timeout",
            "unknown" => "unknown provider failure"
          }.fetch(failure_class)
          "#{@adapter} #{noun}"
        end

        def http_status?(text, status)
          text.match?(/(?:http|status|response)["':=\s-]*#{status}\b/i) ||
            text.match?(/"status"\s*:\s*#{status}\b/i)
        end

        def bounded(evidence)
          text = evidence.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
          text = text.byteslice(text.bytesize - 64 * 1024, 64 * 1024) if text.bytesize > 64 * 1024
          text.to_s.scrub
        end

        def unknown_signal(provider:, evidence:, evidence_ref:)
          text = bounded(evidence)
          ProviderRouting::Signal.new(
            provider: provider.to_s.empty? ? @adapter : provider,
            model: nil,
            failure_class: "unknown",
            scope: "none",
            reset_at: nil,
            safe_summary: "#{@adapter} unknown provider failure",
            fingerprint: "sha256:#{Digest::SHA256.hexdigest(text)}",
            evidence_ref: evidence_ref
          )
        end
      end

      CLAUDE = Normalizer.new(:claude).freeze
      CODEX = Normalizer.new(:codex).freeze
      PI = Normalizer.new(:pi).freeze
      GROK = Normalizer.new(:grok).freeze
    end
  end
end
