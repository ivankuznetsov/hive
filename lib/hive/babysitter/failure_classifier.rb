require "hive/agent_limit"
require "hive/model_unsupported"
require "hive/secret_patterns"

module Hive
  module Babysitter
    # Classifies provider quota, rate-limit, billing/credit, capacity,
    # overloaded, transient-upstream, and local-host operational failures from
    # a babysitter agent spawn result. These failures cannot be fixed in PR
    # code, so PrFixer holds/backs off the provider and records structured
    # local events instead of posting noisy PR comments or applying
    # babysitter/needs-human.
    module FailureClassifier
      Classification = Data.define(:outcome, :reason, :message, :retry_after_text)

      MESSAGE_MAX_BYTES = 500
      LIMIT_PROVIDER_ERROR_KINDS = %i[provider_limit rate_limited].freeze
      LIMIT_STATUS_CODES = [ 402, 429 ].freeze
      LIMIT_SIGNAL_CLASSES = %w[
        account_quota
        exhausted_credits
        provider_rate_limit
        model_quota
        model_rate
      ].freeze

      OPERATIONAL_ERROR_REASONS = %w[
        provider_error
        provider_route_failed
        provider_route_preflight_failed
        authentication_failure
        process_cleanup_failed
      ].freeze

      EXIT_CODE_ONLY_RE = /\Aexit_code=-?\d+\z/.freeze

      # Provider quota / usage-cap / credit / 402 / 429 lines not already
      # covered by Hive::AgentLimit::LIMIT_PATTERNS (for example Claude's
      # "You've hit your limit", Anthropic's "credit balance is too low",
      # Antigravity/Gemini's "exhausted your capacity on this model", or
      # generic "usage cap" / "HTTP 402" / "API Error: 429"). Filtered through
      # AgentLimit::BENIGN_PATTERNS so healthy CLI chrome never trips.
      EXTRA_LIMIT_PATTERNS = [
        /\b(?:hit|reached)\s+your\s+(?:[\w-]+\s+)?limit\b/i,
        /\b(?:usage|rate|spend|spending|account|subscription)\s+cap\b/i,
        /\bcredit\s+balance\s+is\s+too\s+low\b/i,
        /\b(?:out\s+of|insufficient|no\s+remaining|exhausted(?:\s+your)?)\s+(?:[\w-]+\s+)?(?:credits?|quota)\b/i,
        /\b(?:exceeded|over)\s+(?:your\s+)?(?:current\s+)?quota\b/i,
        /\bexhausted\s+your\s+capacity\b/i,
        /\bpayment\s+required\b/i,
        /\b(?:api\s+error|http|status|response|code)[:=\s(\[]*402\b/i,
        /\b(?:rate[_\s-]*limit[_\s-]*error|api\s+error[:=\s(\[]*429|status[:=\s(\[]*429)\b/i
      ].freeze

      # Unambiguous provider capacity / overloaded / 5xx / transient upstream
      # or network errors when a CLI exits non-zero without emitting a
      # structured provider_error event (for example Claude's stream-json
      # result error or raw stderr). Anchored to provider/transport error
      # formats so ordinary failing test summaries never match.
      TRANSIENT_PROVIDER_PATTERNS = [
        /\boverloaded[_\s-]*error\b/i,
        /\b(?:server|api|model|service|engine|provider)\s+(?:is\s+)?(?:currently\s+|temporarily\s+)?overloaded\b/i,
        /\btemporarily\s+(?:overloaded|unavailable)\b/i,
        /\bservice[_\s-]*unavailable\b/i,
        /\b(?:model[_\s-]*)?capacity[_\s-]*(?:exhausted|exceeded)\b/i,
        /\b(?:no\s+capacity\s+available|insufficient\s+capacity|at\s+capacity)\b/i,
        /\bexperiencing\s+high\s+(?:demand|load)\b/i,
        /\b(?:api\s+error|unexpected\s+status|http|status|response)[:=\s(\[]*(?:500|502|503|504|529)\b/i,
        /\b(?:502\s+bad\s+gateway|503\s+(?:service\s+)?unavailable|504\s+gateway\s+timeout)\b/i,
        /\b529\s+(?:site\s+is\s+)?overloaded\b/i,
        /\bupstream\s+(?:error|idle\s+timeout|connect\s+error|request\s+timeout)\b/i,
        /\bstream\s+disconnected\s+before\s+completion\b/i,
        /\bserver\s+had\s+an\s+error\s+while\s+processing\s+your\s+request\b/i,
        /\b(?:econnreset|etimedout|eai_again|enetunreach|ehostunreach)\b/i,
        /\b(?:connection\s+reset\s+by\s+peer|socket\s+hang\s+up|tls\s+handshake\s+timeout)\b/i,
        /\b(?:temporary\s+failure\s+in\s+name\s+resolution|network\s+is\s+unreachable|could\s+not\s+resolve\s+host)\b/i
      ].freeze

      module_function

      def classify(result)
        return nil unless result.is_a?(Hash)
        return nil if result[:status] == :ok && !result[:timed_out]
        return nil if model_unsupported?(result)

        reason = limit_reason(result)
        return build(:limits_reached, reason, result) if reason

        reason = provider_error_reason(result)
        return build(:provider_error, reason, result) if reason

        nil
      end

      def model_unsupported?(result)
        return false unless result.is_a?(Hash)
        return true if result[:error_reason].to_s == Hive::ModelUnsupported::REASON

        provider_error = result[:provider_error]
        provider_error.is_a?(Hash) && Hive::ModelUnsupported.detected?(provider_error[:message].to_s)
      end

      def limit_reason(result)
        return "limits_reached" if result[:error_reason].to_s == "limits_reached"
        return "limits_reached" unless result[:limit_text].to_s.strip.empty?
        return "limits_reached" if Hive::AgentLimit.from_limit?(result[:error_message].to_s)

        reason = provider_error_limit_reason(result[:provider_error]) ||
          provider_signal_limit_reason(result[:provider_signal])
        return reason if reason
        return "limits_reached" if text_candidates(result).any? { |text| limit_text?(text) }

        nil
      end

      def provider_error_reason(result)
        return "preflight_failed" if result[:preflight_failed] == true

        error_reason = result[:error_reason].to_s
        return error_reason if OPERATIONAL_ERROR_REASONS.include?(error_reason)

        provider_error = result[:provider_error]
        if provider_error.is_a?(Hash) && provider_error[:kind]&.to_sym != :model_output_limit
          return "provider_error"
        end

        provider_signal = result[:provider_signal]
        if provider_signal.is_a?(Hash)
          klass = signal_class(provider_signal)
          return klass.empty? ? "provider_signal" : klass
        end

        return "transient_provider_error" if text_candidates(result).any? { |text| transient_provider_text?(text) }

        nil
      end

      def provider_error_limit_reason(provider_error)
        return nil unless provider_error.is_a?(Hash)

        kind = provider_error[:kind]&.to_sym
        return kind.to_s if LIMIT_PROVIDER_ERROR_KINDS.include?(kind)

        status_code = provider_error[:status_code]&.to_i
        return status_code == 429 ? "rate_limited" : "provider_limit" if LIMIT_STATUS_CODES.include?(status_code)
        return "limits_reached" if limit_text?(provider_error[:message])

        nil
      end

      def provider_signal_limit_reason(provider_signal)
        return nil unless provider_signal.is_a?(Hash)

        klass = signal_class(provider_signal)
        LIMIT_SIGNAL_CLASSES.include?(klass) ? klass : nil
      end

      def signal_class(signal)
        (signal["failure_class"] || signal[:failure_class]).to_s.strip
      end

      def text_candidates(result)
        [ result[:error_message], result[:final_message] ]
      end

      def limit_text?(text)
        return true if Hive::AgentLimit.limit_reached?(text)

        matching_line?(text, EXTRA_LIMIT_PATTERNS, ignore_benign: true)
      end

      def transient_provider_text?(text)
        matching_line?(text, TRANSIENT_PROVIDER_PATTERNS, ignore_benign: false)
      end

      def matching_line?(text, patterns, ignore_benign:)
        normalized = Hive::AgentLimit.normalize(text)
        return false if normalized.empty?

        normalized.each_line.any? do |line|
          stripped = line.strip
          next false if stripped.empty?
          next false if ignore_benign && Hive::AgentLimit::BENIGN_PATTERNS.any? { |pattern| stripped.match?(pattern) }

          patterns.any? { |pattern| stripped.match?(pattern) }
        end
      end

      def build(outcome, reason, result)
        provider_message = result[:provider_error].is_a?(Hash) ? result[:provider_error][:message] : nil
        error_message = result[:error_message].to_s.strip
        preferred_error = error_message.match?(EXIT_CODE_ONLY_RE) ? nil : error_message
        retry_after_text = first_present(result[:limit_text], provider_message, preferred_error, result[:final_message])
        raw_message = first_present(preferred_error, provider_message, result[:limit_text], result[:final_message], error_message).to_s
        message = Hive::SecretPatterns.redact(raw_message).strip.byteslice(0, MESSAGE_MAX_BYTES).to_s.scrub
        Classification.new(outcome: outcome, reason: reason, message: message, retry_after_text: retry_after_text)
      end

      def first_present(*values)
        values.map { |value| value.to_s.strip }.find { |value| !value.empty? }
      end
    end
  end
end
