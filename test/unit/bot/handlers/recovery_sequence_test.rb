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
end
