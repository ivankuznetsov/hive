require "test_helper"
require "hive/bot/handlers/recovery_sequence"

class HiveBotRecoverySequenceTest < Minitest::Test
  Result = Struct.new(:action, :text, :command_argv, :commands, :project, :slug,
                      :alert_reset, :clear_keyboard, keyword_init: true)

  def test_build_returns_dispatch_commands_for_retryable_review_error
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "pass=2",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_commands, result.action
    assert_equal "hive", result.project
    assert_equal "stuck-260525-abcd", result.slug
    assert_equal 2, result.commands.length
    assert_equal "markers", result.commands[0][1]
    assert_equal "review", result.commands[1][1]
    refute result.clear_keyboard
  end

  def test_build_short_circuits_on_manual_only_marker
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stale-260525-abcd", stage: "4-execute",
      marker: "execute_stale", match_attr: nil,
      result_class: Result, clear_keyboard: true
    )

    assert_equal :reply, result.action
    assert_match(/no automatic recovery/, result.text)
  end

  def test_build_short_circuits_on_no_retry_verb_stage
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "done-260525-abcd", stage: "9-done",
      marker: "review_error", match_attr: nil,
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/No retry verb for stage 9-done/, result.text)
  end

  def test_retry_commands_skips_markers_clear_for_agent_working_marker
    commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "any-260525-aaaa", stage: "6-review",
      marker: "AGENT_WORKING", match_attr: nil
    )

    assert_equal 1, commands.length, "agent_working marker must NOT add a markers clear step"
    assert_equal "review", commands[0][1]
  end

  def test_retry_commands_includes_match_attr_when_present
    commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "pass=2"
    )

    assert_includes commands[0], "--match-attr"
    assert_includes commands[0], "pass=2"
  end

  def test_retry_commands_omits_match_attr_when_invalid_shape
    commands = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "no_equals_sign"
    )

    refute_includes commands[0], "--match-attr"
  end

  def test_alert_reset_omits_optional_keys_when_blank
    assert_equal({ project: "hive", slug: "s", stage: "6-review" },
                 Hive::Bot::Handlers::RecoverySequence.alert_reset("hive", "s", "6-review"))
    assert_equal({ project: "hive", slug: "s", stage: "6-review", marker: "review_error" },
                 Hive::Bot::Handlers::RecoverySequence.alert_reset("hive", "s", "6-review", "review_error"))
    assert_equal({ project: "hive", slug: "s", stage: "6-review",
                   marker: "review_error", match_attr: "pass=2" },
                 Hive::Bot::Handlers::RecoverySequence.alert_reset(
                   "hive", "s", "6-review", "review_error", "pass=2"
                 ))
  end

  # `stages.ensure_clean_on_exit` plan: `:error reason=dirty_worktree`
  # and `:error reason=ensure_clean_on_exit_failed` must short-circuit
  # the Autofix dispatch with the operator-actionable reply, not the
  # generic "open it on a laptop" string. Asserting the callback path
  # specifically (no `attrs:` kwarg) — that's the one that needed the
  # `match_attr → attrs` resolution.
  def test_build_short_circuits_on_dirty_worktree_via_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-aaaa", stage: "8-finalize",
      marker: "error", match_attr: "reason=dirty_worktree",
      result_class: Result, clear_keyboard: true
    )

    assert_equal :reply, result.action
    assert_match(/Hive can't auto-recover a dirty worktree/, result.text)
    assert_match(/commit or discard/, result.text)
  end

  def test_build_short_circuits_on_ensure_clean_on_exit_failed_via_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-bbbb", stage: "8-finalize",
      marker: "error", match_attr: "reason=ensure_clean_on_exit_failed",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/Hive can't auto-recover a dirty worktree/, result.text)
  end

  # Same routing on the slash-handler path that passes the full row.attrs
  # hash — the attrs-gated rule must fire there too.
  def test_build_short_circuits_on_ensure_clean_on_exit_failed_via_attrs
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-cccc", stage: "8-finalize",
      marker: "error", match_attr: nil,
      attrs: { "reason" => "ensure_clean_on_exit_failed", "residue_paths" => "wiki/modules/daemon.md" },
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/Hive can't auto-recover a dirty worktree/, result.text)
  end

  def test_build_short_circuits_on_fix_status_check_failed_via_attrs
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260530-aaaa", stage: "6-review",
      marker: "review_error", match_attr: nil,
      attrs: { "phase" => "fix", "reason" => "fix_status_check_failed", "pass" => "1" },
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/Git status cannot be read/, result.text)
  end

  # Real-world callback_data carries BOTH `marker_id=<hex>` (the
  # race-safe clear guard from `Hive::Markers.error_recovery_match_attr`)
  # AND `reason=<...>` (so manual_only? can route on reason without
  # re-reading the state file). Before F1, error_recovery_match_attr
  # returned `marker_id=<hex>` alone, attrs_from_match_attr
  # reconstructed `{ "marker_id" => "<hex>" }` with no `reason`, and
  # the manual-only check fell through to the dispatch path — sending
  # a retry against a dirty worktree.
  def test_build_short_circuits_on_marker_id_plus_reason_match_attr
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-eeee", stage: "8-finalize",
      marker: "error",
      match_attr: "marker_id=abc123,reason=ensure_clean_on_exit_failed",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :reply, result.action
    assert_match(/Hive can't auto-recover a dirty worktree/, result.text)
  end

  # Other `:error` reasons keep the existing retry behaviour (clear +
  # retry verb) — the new manual-only routing must be narrowly scoped.
  def test_build_still_dispatches_for_other_error_reasons
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260528-dddd", stage: "8-finalize",
      marker: "error", match_attr: "reason=unpushed_commits",
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_commands, result.action
    assert_equal 2, result.commands.length
    assert_equal "markers", result.commands[0][1]
  end
end
