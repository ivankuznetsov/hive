# frozen_string_literal: true

require "lib/git_restore"

module HiveBench
  # Resolves the `reused` cells of a pass: where a slate agent IS the task's
  # original producer AT THE RECORDED VERSION, we already have its output — re-
  # running would burn credits to reproduce recorded work.
  #
  # IMPORTANT: the corpus `reference.patch` is the human-reviewed, MERGED PR (the
  # gold answer key), NOT a raw agent run — so it is never a contestant cell.
  # The fair incumbent artifact is the producer's RAW execute output, recovered
  # as the hardened diff `base_commit..provenance.execute_base_head`.
  #
  # Matching is version-aware: a corpus produced by `claude-opus-4-7` reuses for
  # the `claude@opus-4.7` cell, while `claude@opus-4.8` does NOT match and runs
  # fresh (a genuine new contestant). Pi (the open-model challenger) never reuses.
  # No cost/fix-pass telemetry is recorded, so a reused cell carries none.
  module Reuse
    module_function

    FAMILY_PATTERNS = {
      "claude" => /\Aclaude/i,
      "codex" => /\A(gpt|codex|o\d)/i
    }.freeze

    # ->(entry, profile) => { diff:, model_version:, telemetry: } | nil
    def resolver(differ: GitRestore.new)
      lambda do |entry, profile|
        producer = entry.dig("provenance", "original_model")
        next nil unless reuses?(producer, profile)

        head = entry.dig("provenance", "execute_base_head")
        base = entry.dig("source", "base_commit")
        repo = entry["checkout_source"]
        next nil unless head && base && repo

        diff = differ.range_diff(repo: repo, base: base, head: head)
        next nil if diff.strip.empty?

        { diff: diff, model_version: producer, telemetry: {} }
      end
    end

    # Reuse iff the agent is the recorded producer's family AND its pinned version
    # matches the recorded one (so a newer version of the same agent runs fresh).
    def reuses?(producer, profile)
      produced_by?(producer, profile.harness) && version_matches?(profile.model, producer)
    end

    def produced_by?(producer, harness)
      pattern = FAMILY_PATTERNS[harness]
      pattern ? producer.to_s.match?(pattern) : false
    end

    # Compare the dotted version cores, tolerant of `-`/`.` separators and suffixes
    # (e.g. "opus-4.7" vs "claude-opus-4-7[1m]" -> both "4.7").
    def version_matches?(profile_model, producer)
      v = version_core(profile_model)
      !v.empty? && v == version_core(producer)
    end

    def version_core(text)
      text.to_s.tr("-", ".")[/\d+\.\d+/].to_s
    end
  end
end
