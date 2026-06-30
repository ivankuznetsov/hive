require "test_helper"
require "hive/claude_completion_fallback"

class ClaudeCompletionFallbackTest < Minitest::Test
  def base_evidence
    {
      pane_idle: true,
      process_exited: nil,
      exit_code: nil,
      tmux_readable: true,
      session_alive: true,
      reason: "turn_ended_without_stop_hook"
    }
  end

  def base_phase_facts
    {
      artifacts_present: true,
      commit_or_no_change: true,
      no_unresolved_escalation: true,
      worktree_readable: true,
      missing_output_absent: true
    }
  end

  def decision(evidence: base_evidence, phase_facts: base_phase_facts)
    Hive::ClaudeCompletionFallback.suppress?(evidence: evidence, phase_facts: phase_facts)
  end

  def test_suppresses_when_generic_and_phase_conditions_hold
    result = decision

    assert_equal true, result.fetch(:suppress)
    assert_equal [], result.fetch(:missing)
  end

  def test_process_crash_blocks_suppression
    # The tmux REPL never produces a real per-turn exit_code (it is
    # advisory-only / always nil — see ClaudeLauncher#completion_evidence),
    # so crash protection does NOT rest on a synthetic 137. A crashed
    # Claude leaves no commit and no whole-pass no-change evidence, so the
    # commit_or_no_change phase fact is what actually blocks suppression.
    result = decision(
      evidence: base_evidence.merge(pane_idle: false, process_exited: true, exit_code: nil),
      phase_facts: base_phase_facts.merge(commit_or_no_change: false)
    )

    assert_equal false, result.fetch(:suppress)
    assert_includes result.fetch(:missing), "commit_or_no_change"
  end

  def test_gone_session_blocks_suppression
    # A clean `session_exists? == false` reports session_alive: false with
    # an empty session_error; the tmux_readable/session_error guard misses
    # it, so the explicit session_alive guard must keep gone tmux terminal.
    result = decision(evidence: base_evidence.merge(session_alive: false))

    assert_equal false, result.fetch(:suppress)
    assert_includes result.fetch(:missing), "session_alive"
  end

  def test_unknown_session_alive_does_not_block_suppression
    result = decision(evidence: base_evidence.merge(session_alive: nil))

    assert_equal true, result.fetch(:suppress)
  end

  def test_missing_artifacts_block_suppression
    result = decision(phase_facts: base_phase_facts.merge(artifacts_present: false))

    assert_equal false, result.fetch(:suppress)
    assert_includes result.fetch(:missing), "artifacts_present"
  end

  def test_missing_commit_or_no_change_evidence_blocks_suppression
    result = decision(phase_facts: base_phase_facts.merge(commit_or_no_change: false))

    assert_equal false, result.fetch(:suppress)
    assert_includes result.fetch(:missing), "commit_or_no_change"
  end

  def test_unresolved_escalation_blocks_suppression
    result = decision(phase_facts: base_phase_facts.merge(no_unresolved_escalation: false))

    assert_equal false, result.fetch(:suppress)
    assert_includes result.fetch(:missing), "no_unresolved_escalation"
  end

  def test_unknown_completion_evidence_blocks_suppression
    result = decision(evidence: base_evidence.merge(pane_idle: nil, process_exited: nil))

    assert_equal false, result.fetch(:suppress)
    assert_includes result.fetch(:missing), "normal_completion"
  end

  def test_limit_wall_blocks_suppression
    result = decision(evidence: base_evidence.merge(reason: "limits_reached"))

    assert_equal false, result.fetch(:suppress)
    assert_includes result.fetch(:missing), "limit_wall"
  end

  def test_tmux_unreadable_blocks_suppression
    result = decision(evidence: base_evidence.merge(tmux_readable: false, session_error: "server disappeared"))

    assert_equal false, result.fetch(:suppress)
    assert_includes result.fetch(:missing), "tmux_readable"
  end

  def test_string_keys_are_accepted
    result = Hive::ClaudeCompletionFallback.suppress?(
      evidence: base_evidence.transform_keys(&:to_s),
      phase_facts: base_phase_facts.transform_keys(&:to_s)
    )

    assert_equal true, result.fetch(:suppress)
  end
end
