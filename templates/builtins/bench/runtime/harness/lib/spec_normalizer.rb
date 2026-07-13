# frozen_string_literal: true

module HiveBench
  # Makes a hive task's frozen plan/spec portable so it replays against a
  # restored checkout on any machine, not just the one it was authored on.
  #
  # Two transforms (plan U1 / R3):
  #   1. Rewrite absolute filesystem paths to a `<REPO_ROOT>` placeholder so a
  #      candidate agent isn't handed dead paths from the author's machine.
  #   2. Flag repo-state assertions ("there is no X today", "currently …") with
  #      an inline marker, because they describe the repo as it was at authoring
  #      time and may be false against the restored base — the candidate should
  #      treat them as context, not ground truth.
  #
  # Deliberately conservative: it rewrites only paths it is confident about and
  # only annotates (never deletes) prose, so normalization can't silently change
  # the meaning of a plan.
  module SpecNormalizer
    module_function

    REPO_ROOT_PLACEHOLDER = "<REPO_ROOT>"

    # Absolute worktree paths first (more specific), then generic home-rooted
    # project paths. Both collapse to the placeholder + whatever sub-path
    # followed the project root, so `/home/x/hive/lib/foo.rb` -> `<REPO_ROOT>/lib/foo.rb`.
    WORKTREE_PATH = %r{/(?:home|Users)/[^/\s]+/(?:Dev/)?[\w.-]+\.worktrees/[\w.-]+(?<rest>/[^\s"'`)\]]*)?}
    PROJECT_PATH  = %r{/(?:home|Users)/[^/\s]+/(?:Dev/)?[\w.-]+(?<rest>/[^\s"'`)\]]*)?}

    # Phrases that assert the repo's current state at authoring time. Matched
    # case-insensitively against each line; a matching line gets an inline
    # annotation rather than removal.
    STATE_ASSERTION = /
      \b(?:
        there\s(?:is|are)\sno\b | today\b | currently\b | as\sit\sstands\b |
        right\snow\b | does\snot\s(?:exist|yet)\b | no\s.{0,40}\s(?:exists?|yet)\b
      )
    /xi

    STATE_MARKER = " <!-- hive-bench: repo-state assertion, verify against the restored base -->"

    # Returns the normalized text. Idempotent: running it twice is a no-op
    # (the marker itself contains no path and no state phrase that re-triggers).
    # Tracks fenced-code state so prose-assertion annotation never lands inside
    # a ``` block (path rewriting still applies everywhere — a dead path in a
    # code sample is as useless to the candidate as one in prose).
    def normalize(text)
      return "" if text.nil?

      in_fence = false
      text.each_line.map do |line|
        if line.strip.start_with?("```")
          in_fence = !in_fence
          next rewrite_paths(line)
        end
        normalize_line(line, in_fence: in_fence)
      end.join
    end

    # Reports what normalization would change, without applying it — used by the
    # extractor to record provenance and by tests to assert specific rewrites.
    def analyze(text)
      paths = []
      assertions = []
      (text || "").each_line.with_index do |line, i|
        paths << { line: i + 1, text: line.strip } if line.match?(WORKTREE_PATH) || line.match?(PROJECT_PATH)
        assertions << { line: i + 1, text: line.strip } if state_assertion?(line)
      end
      { rewritten_paths: paths, flagged_assertions: assertions }
    end

    def normalize_line(line, in_fence: false)
      rewritten = rewrite_paths(line)
      return rewritten if in_fence
      return rewritten if rewritten.include?(STATE_MARKER.strip)
      return annotate_assertion(rewritten) if state_assertion?(rewritten)

      rewritten
    end
    private_class_method :normalize_line

    def rewrite_paths(line)
      line
        .gsub(WORKTREE_PATH) { "#{REPO_ROOT_PLACEHOLDER}#{Regexp.last_match(:rest)}" }
        .gsub(PROJECT_PATH)  { "#{REPO_ROOT_PLACEHOLDER}#{Regexp.last_match(:rest)}" }
    end
    private_class_method :rewrite_paths

    # True only for prose state assertions — skip fenced/indented code and
    # markdown structure so we annotate intent, not implementation text.
    def state_assertion?(line)
      stripped = line.strip
      return false if stripped.empty?
      return false if stripped.start_with?("```", "    ", "\t", "|", "#")

      stripped.match?(STATE_ASSERTION)
    end
    private_class_method :state_assertion?

    def annotate_assertion(line)
      newline = line.end_with?("\n") ? "\n" : ""
      "#{line.chomp}#{STATE_MARKER}#{newline}"
    end
    private_class_method :annotate_assertion
  end
end
