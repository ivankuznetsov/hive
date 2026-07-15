# frozen_string_literal: true

module HiveBench
  # Maps model/agent identifier strings to a model FAMILY, so scoring can flag
  # judge scores where the judge shares a family with the candidate it graded
  # (LLM self-preference bias). The v1 "the judge is family-disjoint from every
  # contestant" guarantee broke the moment opus judged an opus candidate — v2
  # keeps both judges but marks same-family scores so the leaderboard can build
  # its headline from cross-family scores only.
  #
  # Matching is substring-based over ids like "all-opus-4.8", "claude-opus-4-8",
  # "opus-plan->codex-exec", "gpt-5.5-pro", "pi@glm-5.2" — a mixed candidate
  # legitimately belongs to several families.
  module ModelFamily
    module_function

    FAMILIES = {
      "anthropic" => /claude|opus|sonnet|haiku|fable|mythos/i,
      "openai" => /gpt|codex|\bo[0-9]\b/i,
      "xai" => /grok/i,
      "zhipu" => /glm/i,
      "moonshot" => /kimi/i,
      "alibaba" => /qwen/i,
      "minimax" => /minimax/i,
      "google" => /gemini/i
    }.freeze

    # All families named anywhere in the given strings (agent id, model version,
    # judge name, …). Empty when nothing matched — treated as "unknown", which
    # never counts as a same-family hit (an unknown judge isn't assumed biased,
    # but an unknown CANDIDATE also can't be cleared — keep ids family-legible).
    def families(*strings)
      text = strings.compact.join(" ")
      FAMILIES.select { |_, rx| text.match?(rx) }.keys
    end

    def same_family?(judge_name, *candidate_strings)
      families(judge_name).intersect?(families(*candidate_strings))
    end
  end
end
