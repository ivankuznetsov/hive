# frozen_string_literal: true

require "lib/model_family"

module HiveBench
  # API-equivalent cost from token counts at USUAL-tier (standard) rates — the
  # methodology decision: self-reported CLI cost is inconsistent across agents
  # (claude accounts at the fast tier, codex/pi may report nothing), so the
  # comparable number is tokens × a versioned price table. For open models this
  # equals actual billed spend; for subscription-run closed models it is what the
  # tokens would cost at API rates.
  module Pricing
    module_function

    TABLE_VERSION = "2026-06-usual"

    # $ per 1M tokens: input / output / cached-input (OpenRouter standard tiers,
    # the rates RESULTS.md v1 published).
    RATES = {
      "anthropic" => { "input" => 5.00, "output" => 25.00, "cached" => 0.50 },
      "openai" => { "input" => 5.00, "output" => 30.00, "cached" => 0.50 },
      "zhipu" => { "input" => 0.95, "output" => 3.00, "cached" => 0.18 },
      "moonshot" => { "input" => 0.74, "output" => 3.50, "cached" => 0.15 }
    }.freeze

    # Model-level tiers checked BEFORE the family rate: haiku is anthropic-family
    # but priced far below opus — family rates would inflate the CLI's utility
    # calls (haiku does claude's internal subtasks) by 5x.
    MODEL_RATES = [
      [/haiku/i, { "input" => 1.00, "output" => 5.00, "cached" => 0.10 }]
    ].freeze

    # Price a token bundle for a single-family candidate. Returns nil when the
    # family is ambiguous (mixed candidates need per-stage token attribution —
    # not implemented) or unpriced — a nil is honest; a wrong-rate number is not.
    # cache_creation (cache WRITES) is priced at the plain input rate — a slight
    # undercount for claude (bills ~1.25x input) but far closer than dropping it.
    def estimate_usd(model_strings:, input: 0, output: 0, cached: 0, cache_creation: 0)
      text = model_strings.compact.join(" ")
      rates = MODEL_RATES.find { |rx, _| text.match?(rx) }&.last
      unless rates
        families = ModelFamily.families(*model_strings)
        return nil unless families.size == 1

        rates = RATES[families.first] or return nil
      end
      ((((input.to_i + cache_creation.to_i) * rates["input"]) +
        (output.to_i * rates["output"]) +
        (cached.to_i * rates["cached"])) / 1_000_000.0).round(4)
    end
  end
end
