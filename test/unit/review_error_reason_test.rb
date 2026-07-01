require "test_helper"
require "hive/review_error_reason"

class ReviewErrorReasonTest < Minitest::Test
  def test_detects_merge_conflict
    assert_equal "merge_conflict",
                 Hive::ReviewErrorReason.classify("CONFLICT (content): Merge conflict in lib/app.rb")
  end

  def test_detects_network_timeout
    assert_equal "network_timeout",
                 Hive::ReviewErrorReason.classify("Fetch failed: connect timed out while opening socket")
  end

  def test_detects_tool_permission_denied
    assert_equal "tool_permission_denied",
                 Hive::ReviewErrorReason.classify("tool shell_command blocked: permission denied")
  end

  def test_detects_agent_crashed
    assert_equal "agent_crashed",
                 Hive::ReviewErrorReason.classify("Traceback (most recent call last):")
  end

  def test_first_match_wins_by_reason_priority
    text = <<~TEXT
      process killed by signal
      Automatic merge failed; fix conflicts and then commit the result.
    TEXT

    assert_equal "merge_conflict", Hive::ReviewErrorReason.classify(text)
  end

  def test_unrecognized_text_is_unknown
    assert_equal "unknown",
                 Hive::ReviewErrorReason.classify("expected output file was not written before deadline")
  end

  def test_blank_and_nil_are_unknown
    assert_equal "unknown", Hive::ReviewErrorReason.classify("")
    assert_equal "unknown", Hive::ReviewErrorReason.classify(" \n\t ")
    assert_equal "unknown", Hive::ReviewErrorReason.classify(nil)
  end

  def test_ansi_and_control_characters_are_normalized_before_classification
    text = "\e[31mPermission denied\e[0m\u0007 while calling tool"

    assert_equal "tool_permission_denied", Hive::ReviewErrorReason.classify(text)
  end

  def test_classified_outputs_are_closed_over_enum
    emitted = Hive::ReviewErrorReason::CLASSIFIED + [ "unknown" ]

    assert_empty emitted - Hive::ReviewErrorReason::REASONS
  end

  # One representative line per regex alternative, in PATTERNS order. Each line
  # is crafted to match EXACTLY its target alternative (not a sibling of the
  # same reason). test_every_pattern_alternative_has_a_representative_line zips
  # this table against the flattened PATTERNS regexes and asserts line[i]
  # matches regex[i], so a one-character typo in any single regex flips its
  # bound line to a non-match and fails there. Count parity alone would let an
  # edit double-cover one alternative and orphan another while staying green;
  # binding each line to its own regex closes that gap. The 100% line-coverage
  # gate cannot catch this because the regex array literals read as covered
  # after one classify call. Keep this table in lockstep with PATTERNS (order
  # included).
  REPRESENTATIVE_LINES = {
    # merge_conflict
    "CONFLICT (content): collision in file" => "merge_conflict",
    "Merge conflict in lib/app.rb" => "merge_conflict",
    "Automatic merge failed; stopping" => "merge_conflict",
    "path/to/file.rb: needs merge" => "merge_conflict",
    "You have unmerged paths." => "merge_conflict",
    "hint: fix conflicts and then commit the result" => "merge_conflict",
    "rebase conflict" => "merge_conflict",
    # network_timeout
    "connection timed out" => "network_timeout",
    "Error: ETIMEDOUT opening socket" => "network_timeout",
    "connect to host github.com: Network is unreachable" => "network_timeout",
    "getaddrinfo: Temporary failure in name resolution" => "network_timeout",
    "fatal: unable to access: Could not resolve host: github.com" => "network_timeout",
    "Error: ECONNRESET" => "network_timeout",
    "Connection reset by peer" => "network_timeout",
    # tool_permission_denied
    "bash: /usr/bin/foo: Permission denied" => "tool_permission_denied",
    "Error: EACCES open '/etc/hosts'" => "tool_permission_denied",
    "rm: cannot remove: Operation not permitted" => "tool_permission_denied",
    "agent is not allowed to run Bash" => "tool_permission_denied",
    "tool shell_command blocked" => "tool_permission_denied",
    "hook: refusing to run untrusted command" => "tool_permission_denied",
    # agent_crashed
    "Segmentation fault" => "agent_crashed",
    "Process received SIGSEGV" => "agent_crashed",
    "Aborted by SIGABRT" => "agent_crashed",
    "panic: runtime error: index out of range" => "agent_crashed",
    "fatal error: runtime: out of memory" => "agent_crashed",
    "Uncaught exception: TypeError" => "agent_crashed",
    "Traceback (most recent call last):" => "agent_crashed",
    "Killed" => "agent_crashed",
    "process exited: core dumped" => "agent_crashed",
    "terminated by SIGKILL" => "agent_crashed"
  }.freeze

  def test_every_pattern_alternative_has_a_representative_line
    flat_regexes = Hive::ReviewErrorReason::PATTERNS.flat_map do |reason, regexes|
      regexes.map { |regex| [ reason, regex ] }
    end
    bound = REPRESENTATIVE_LINES.to_a

    assert_equal flat_regexes.size, bound.size,
                 "every regex alternative in PATTERNS needs exactly one representative line (same order)"

    # Bind line[i] to regex[i]: a per-regex typo flips its own line to a
    # non-match and fails here even if a sibling alternative still classifies
    # the reason (the double-cover/orphan hole count parity alone leaves open).
    flat_regexes.zip(bound).each do |(reason, regex), (line, expected)|
      assert_equal reason, expected,
                   "representative line #{line.inspect} is out of PATTERNS order: bound to #{reason}, tagged #{expected}"
      assert_match regex, line.strip,
                   "#{line.inspect} must match its bound #{reason} alternative #{regex.inspect}"
    end
  end

  def test_representative_lines_classify_to_expected_reason
    REPRESENTATIVE_LINES.each do |line, expected|
      assert_equal expected, Hive::ReviewErrorReason.classify(line),
                   "#{line.inspect} should classify as #{expected}"
    end
  end

  # The classifier matches per stripped line, never across the whole blob:
  # a signal whose words straddle a newline must NOT match. Pinning this
  # stops a future refactor to whole-string match? from silently changing
  # behavior under a green suite.
  def test_signal_split_across_newline_is_not_matched
    straddling = "automatic merge\nfailed to write output"
    assert_equal "unknown", Hive::ReviewErrorReason.classify(straddling)

    on_one_line = "automatic merge failed to write output"
    assert_equal "merge_conflict", Hive::ReviewErrorReason.classify(on_one_line)
  end

  def test_rate_limit_language_is_reserved_for_agent_limit_gate
    assert_equal "unknown", Hive::ReviewErrorReason.classify("rate limit reached")
    assert Hive::AgentLimit.limit_reached?("rate limit reached")
  end

  # The realistic wrapper strings the triage/fix plumbing actually forwards
  # (see ReviewErrorReason.classify's input-contract note) plus benign agent
  # narration must classify to `unknown`, not a specific bucket. The positive
  # tables above prove the patterns FIRE; this proves they don't OVER-fire on
  # prose. Notably the launcher's own `tmux_session_terminated` signature — a
  # real error_message that reaches classify — is pinned here, so a future
  # regex broadening (e.g. adding /terminated/i to agent_crashed) that
  # reclassified an infra timeout as a crash fails loudly instead of silently.
  NON_FIRING_LINES = [
    "expected output file missing or empty: /tmp/out/review.md",
    "tmux_session_terminated before writing expected output file: /tmp/out/review.md",
    "tmux_pane_unreadable: no server running on /tmp/tmux-1000/default",
    "claude stop hook did not signal completion",
    "triage agent failed (timeout)",
    "fix agent failed (error)",
    "exit_code=1",
    "deadline reached before prompt was sent",
    "Applied the requested fix and committed it cleanly.",
    "All checks passed; nothing else to do."
  ].freeze

  def test_realistic_wrapper_strings_and_narration_stay_unknown
    NON_FIRING_LINES.each do |line|
      assert_equal "unknown", Hive::ReviewErrorReason.classify(line),
                   "#{line.inspect} must fall back to unknown, not a specific bucket"
    end
  end
end
