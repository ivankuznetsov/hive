module AgentCliRuntime
  module UsageExtractors
    module_function

    CLAUDE = lambda do |event|
      next nil unless event.is_a?(Hash)

      usage = usage_hash(event)
      if event["type"] == "result" && usage
        usage_result(event, usage, model_from(event), provider: :claude)
      elsif event["type"] == "stream_event" && usage
        usage_result(event, usage, model_from(event), provider: :claude)
      end
    end

    CODEX = lambda do |event|
      next nil unless event.is_a?(Hash)

      usage = usage_hash(event)
      usage_result(event, usage, model_from(event), provider: :codex) if usage
    end

    PI = lambda do |event|
      next nil unless event.is_a?(Hash)

      usage = usage_hash(event)
      usage_result(event, usage, model_from(event), provider: :pi) if usage
    end

    GROK = lambda do |event|
      next nil unless event.is_a?(Hash)

      usage = usage_hash(event)
      usage_result(event, usage, model_from(event), provider: :grok) if usage
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

    def usage_result(event, usage, model, provider:)
      cache_read = cache_read_tokens(usage)
      cache_write = cache_write_tokens(usage)
      aggregate_cached = aggregate_cached_tokens(usage)
      reasoning = optional_token_count(
        usage, "reasoning_tokens", "reasoningTokens"
      )
      reasoning ||= optional_token_count(
        nested_hash(usage, "completion_tokens_details"),
        "reasoning_tokens", "reasoningTokens"
      )
      {
        input: optional_token_count(
          usage, "input_tokens", "inputTokens", "prompt_tokens", "promptTokens"
        ),
        output: optional_token_count(
          usage, "output_tokens", "outputTokens", "completion_tokens",
          "completionTokens"
        ),
        cached: aggregate_cached || complete_cached(cache_read, cache_write),
        cache_read: cache_read,
        cache_write: cache_write,
        reasoning: reasoning,
        input_includes_cache_read:
          inclusion_or_inferred(
            usage, "input_includes_cache_read",
            inferred_input_cache_inclusion(provider, cache_read)
          ),
        input_includes_cache_write:
          inclusion_or_inferred(
            usage, "input_includes_cache_write",
            inferred_input_cache_inclusion(provider, cache_write)
          ),
        output_includes_reasoning:
          inclusion_or_inferred(
            usage, "output_includes_reasoning",
            inferred_reasoning_inclusion(provider, reasoning)
          ),
        model: model || model_from_usage(usage) || model_from(event)
      }
    end

    def aggregate_cached_tokens(usage)
      optional_token_count(
        usage, "cached", "cached_tokens", "cachedTokens",
        "cached_input_tokens", "cachedInputTokens"
      )
    end

    def cache_read_tokens(usage)
      optional_token_count(
        usage, "cache_read_input_tokens", "cacheReadInputTokens"
      ) || optional_token_count(
        nested_hash(usage, "prompt_tokens_details"), "cached_tokens", "cachedTokens"
      ) || optional_token_count(
        nested_hash(usage, "input_tokens_details"), "cached_tokens", "cachedTokens"
      )
    end

    def cache_write_tokens(usage)
      optional_token_count(
        usage, "cache_creation_input_tokens", "cacheCreationInputTokens",
        "cache_write_input_tokens", "cacheWriteInputTokens"
      )
    end

    def complete_cached(cache_read, cache_write)
      return nil if cache_read.nil? || cache_write.nil?

      cache_read + cache_write
    end

    def inferred_input_cache_inclusion(provider, value)
      return nil if value.nil?
      return false if provider == :claude
      return true if provider == :codex

      nil
    end

    def inferred_reasoning_inclusion(provider, value)
      return nil if value.nil?

      provider == :codex ? true : nil
    end

    def inclusion_or_inferred(hash, key, inferred)
      return inferred unless hash.is_a?(Hash) && hash.key?(key)

      value = hash[key]
      value if value == true || value == false
    end

    def optional_token_count(hash, *keys)
      return nil unless hash.is_a?(Hash)

      key = keys.find { |candidate| hash.key?(candidate) }
      key ? hash[key].to_i : nil
    end

    def nested_hash(hash, key)
      value = hash[key]
      value.is_a?(Hash) ? value : {}
    end

    def model_from(event)
      model_usage = event["modelUsage"]
      if model_usage.is_a?(Hash) && !model_usage.empty?
        return model_usage.keys.first.to_s
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
