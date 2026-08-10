module Hive
  module AgentProfiles
    # Conservative adapter-boundary normalization for explicit provider
    # routes. Only exact, structured transport envelopes are accepted. Raw
    # text, assistant/final messages, tool output, and loosely inferred HTTP
    # errors are deliberately outside this contract.
    module ErrorNormalizers
      MAX_RESET_HINT_SECONDS = 7 * 24 * 60 * 60
      PROVIDER_CLASSES = %w[
        authentication billing_configuration exhausted_credits account_quota
        provider_rate_limit provider_outage
      ].freeze
      MODEL_CLASSES = %w[
        unavailable disabled deprecated model_quota model_rate model_capacity
      ].freeze
      ADAPTERS = {
        "claude" => {
          provenance: "claude_stream_json_transport",
          extractor: lambda do |event|
            event["type"] == "provider_error" && event["origin"] == "provider_transport" ?
              event["error"] : nil
          end
        },
        "codex" => {
          provenance: "codex_jsonl_transport",
          extractor: lambda do |event|
            error = event["error"]
            event["type"] == "turn.failed" && error.is_a?(Hash) &&
              error["type"] == "provider_error" && error["origin"] == "provider_transport" ?
              error : nil
          end
        },
        "pi" => {
          provenance: "pi_json_transport",
          extractor: lambda do |event|
            error = event["error"]
            event["type"] == "agent_error" && error.is_a?(Hash) &&
              error["type"] == "provider_error" && error["origin"] == "provider_transport" ?
              error : nil
          end
        },
        "grok" => {
          provenance: "grok_streaming_json_transport",
          extractor: lambda do |event|
            event["type"] == "error" && event["origin"] == "provider_transport" ?
              event["error"] : nil
          end
        }
      }.freeze

      SIGNAL_KEYS = %w[failure_class provenance reset_hint_seconds scope].freeze

      module_function

      def normalize(adapter:, event:, route:)
        adapter_name = adapter.to_s
        contract = ADAPTERS[adapter_name]
        return nil unless contract && event.is_a?(Hash) && route.is_a?(Hash)
        return nil unless route["adapter"].to_s == adapter_name

        error = contract.fetch(:extractor).call(event)
        return nil unless error.is_a?(Hash)

        build_signal(
          error,
          route: route,
          provenance: contract.fetch(:provenance)
        )
      rescue ArgumentError, TypeError
        nil
      end

      # Provider diagnostics use a distinct trusted input rather than the
      # agent's stdout stream. Callers must already have separated and
      # authenticated that channel before invoking this method.
      def normalize_diagnostic(diagnostic:, route:)
        return nil unless diagnostic.is_a?(Hash) && diagnostic["type"] == "provider_diagnostic"

        build_signal(diagnostic, route: route, provenance: "provider_diagnostic")
      rescue ArgumentError, TypeError
        nil
      end

      def build_signal(error, route:, provenance:)
        klass = error["class"].to_s
        kind = error["scope"].to_s
        allowed = kind == "provider_account" ? PROVIDER_CLASSES : MODEL_CLASSES
        return nil unless allowed.include?(klass)
        return nil unless error["provider_account_id"].to_s == route["provider_account_id"].to_s

        model = kind == "model" ? error["model"].to_s : nil
        return nil if kind == "model" && model != route["model"].to_s
        return nil unless %w[provider_account model].include?(kind)
        return nil if kind == "provider_account" && error.key?("model") && !error["model"].nil?

        hint = error["reset_hint_seconds"]
        return nil unless hint.nil? || (hint.is_a?(Integer) && hint.between?(0, MAX_RESET_HINT_SECONDS))

        {
          "failure_class" => klass.freeze,
          "scope" => {
            "kind" => kind.freeze,
            "provider_account_id" => route.fetch("provider_account_id").to_s.freeze,
            "model" => model&.freeze
          }.freeze,
          "provenance" => provenance.freeze,
          "reset_hint_seconds" => hint
        }.freeze
      end
      private_class_method :build_signal
    end
  end
end
