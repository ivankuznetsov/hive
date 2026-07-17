require "test_helper"
require "hive/bot/handlers/recovery_sequence"

class HiveBotRecoverySequenceTest < Minitest::Test
  Result = Struct.new(:action, :text, :command_argv, :commands, :project, :slug,
                      :alert_reset, :clear_keyboard, keyword_init: true)

  def test_build_returns_one_generation_fenced_coordinator_request
    result = Hive::Bot::Handlers::RecoverySequence.build(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "pass=2", generation: 7,
      result_class: Result, clear_keyboard: false
    )

    assert_equal :dispatch_commands, result.action
    assert_equal [ %w[hive retry manual stuck-260525-abcd --project hive --generation 7 --json] ],
                 result.commands
    refute result.clear_keyboard
  end

  def test_failure_class_marker_and_workflow_do_not_change_request
    review = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
      marker: "review_error", match_attr: "pass=2", generation: 11
    )
    auth = Hive::Bot::Handlers::RecoverySequence.retry_commands(
      project: "hive", slug: "stuck-260525-abcd", stage: "2-gather",
      marker: "error", match_attr: "reason=codex_auth", workflow: "research", generation: 11
    )

    assert_equal review, auth
    refute(review.flatten.include?("markers"), "operator recovery must never clear a marker")
    refute(review.flatten.include?("run"), "operator recovery must never bypass the coordinator")
  end

  def test_missing_or_invalid_generation_refuses_dispatch
    [ nil, "latest", -1 ].each do |generation|
      result = Hive::Bot::Handlers::RecoverySequence.build(
        project: "hive", slug: "stuck-260525-abcd", stage: "6-review",
        marker: "review_error", match_attr: nil, generation: generation,
        result_class: Result, clear_keyboard: true
      )

      assert_equal :reply, result.action
      assert_match(/Refresh status/, result.text)
    end
  end

  def test_alert_reset_retains_observation_identity_only
    assert_equal(
      { project: "hive", slug: "s", stage: "6-review", marker: "review_error", match_attr: "pass=2" },
      Hive::Bot::Handlers::RecoverySequence.alert_reset(
        "hive", "s", "6-review", "review_error", "pass=2"
      )
    )
  end
end
