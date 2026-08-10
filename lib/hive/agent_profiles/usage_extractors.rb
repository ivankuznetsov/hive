module Hive
  module AgentProfiles
    module UsageExtractors
      module_function

      CLAUDE = lambda do |event|
        next nil unless event.is_a?(Hash)

        usage = usage_hash(event)
        if event["type"] == "result" && usage
          usage_result(event, usage, model_from(event))
        elsif event["type"] == "stream_event" && usage
          usage_result(event, usage, model_from(event))
        else
          nil
        end
      end

      CODEX = lambda do |event|
        next nil unless event.is_a?(Hash)

        usage = usage_hash(event)
        usage_result(event, usage, model_from(event)) if usage
      end

      # Grok's streaming-json currently carries no usage counts. Preserve
      # unavailable usage as nil rather than polluting aggregates with a
      # fabricated measured zero. If a future CLI adds usage, consume it.
      GROK = lambda do |event|
        next nil unless event.is_a?(Hash)

        usage = usage_hash(event)
        usage_result(event, usage, model_from(event)) if usage
      end

      PI = lambda do |event|
        next nil unless event.is_a?(Hash)

        usage = usage_hash(event)
        usage_result(event, usage, model_from(event)) if usage
      end

      def usage_hash(event)
        candidates = [
          event["usage"],
          event["token_usage"],
          event.dig("event", "usage"),
          event.dig("event", "message", "usage"),
          event.dig("info", "usage"),
          event.dig("info", "total_token_usage"),
          event.dig("response", "usage"),
          event.dig("item", "usage")
        ]
        candidates.find { |value| value.is_a?(Hash) }
      end

      def usage_result(event, usage, model)
        {
          input: token_count(usage, "input_tokens", "inputTokens", "prompt_tokens", "promptTokens"),
          output: token_count(usage, "output_tokens", "outputTokens", "completion_tokens", "completionTokens"),
          cached: cached_tokens(usage),
          model: model || model_from_usage(usage) || model_from(event)
        }
      end

      def cached_tokens(usage)
        direct = token_count(
          usage,
          "cached",
          "cached_tokens",
          "cachedTokens",
          "cached_input_tokens",
          "cachedInputTokens"
        )
        return direct if direct.positive?

        token_count(usage, "cache_read_input_tokens", "cacheReadInputTokens") +
          token_count(usage, "cache_creation_input_tokens", "cacheCreationInputTokens") +
          token_count(nested_hash(usage, "prompt_tokens_details"), "cached_tokens", "cachedTokens") +
          token_count(nested_hash(usage, "input_tokens_details"), "cached_tokens", "cachedTokens")
      end

      def token_count(hash, *keys)
        return 0 unless hash.is_a?(Hash)

        key = keys.find { |candidate| hash.key?(candidate) }
        return 0 unless key

        hash[key].to_i
      end

      def nested_hash(hash, key)
        value = hash[key]
        value.is_a?(Hash) ? value : {}
      end

      def model_from(event)
        from_model_usage = event["modelUsage"]
        if from_model_usage.is_a?(Hash) && !from_model_usage.empty?
          return from_model_usage.keys.first.to_s
        end

        candidates = [
          event["model"],
          event.dig("message", "model"),
          event.dig("event", "message", "model"),
          event.dig("response", "model"),
          event.dig("item", "model")
        ]
        candidates.find { |value| !value.to_s.empty? }&.to_s
      end

      def model_from_usage(usage)
        value = usage["model"] || usage["model_name"] || usage["modelName"]
        value.to_s.empty? ? nil : value.to_s
      end
    end
  end
end
