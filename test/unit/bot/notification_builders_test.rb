require "test_helper"
require "hive/bot/status_watcher"
require "hive/bot/notification_builders"

class HiveBotNotificationBuildersTest < Minitest::Test
  Row = Hive::Bot::StatusWatcher::Row

  def row(action:, marker:, attrs: {}, slug: "slug-260514-abcd", stage: "2-brainstorm")
    Row.new(
      project: "hive",
      slug: slug,
      stage: stage,
      marker: marker,
      attrs: attrs,
      folder: "/tmp/#{slug}",
      action: action,
      action_label: "label",
      suggested_command: nil
    )
  end

  def test_ready_to_plan_builds_approval_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_plan", marker: "complete")
    )

    assert_match(/Ready for plan/, notification.text)
    assert_equal "Approve", notification.keyboard.first.first[:text]
    assert_match(/\Aapprove:plan:hive:slug-260514-abcd:2-brainstorm\z/,
                 notification.keyboard.first.first[:callback_data])
  end

  def test_waiting_builds_brainstorm_answer_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "waiting")
    )

    assert_match(/Brainstorm questions/, notification.text)
    assert_equal "Answer in chat", notification.keyboard.first.first[:text]
    assert_equal "Ask Codex", notification.keyboard[1].first[:text]
  end

  def test_compacted_callback_round_trips
    long_slug = "slug-" + ("a" * 80)
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "ready_to_plan", marker: "complete", slug: long_slug)
    )
    token = notification.keyboard.first.first[:callback_data]

    assert_operator token.bytesize, :<=, Hive::Bot::NotificationBuilders::CALLBACK_DATA_MAX
    assert_match(/\A#approve:/, token)
    assert_equal "approve:plan:hive:#{long_slug}:2-brainstorm",
                 Hive::Bot::NotificationBuilders.resolve_callback(token)
  end

  def test_review_waiting_fix_guardrail_builds_operator_keyboard_without_invalid_clear
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "needs_input", marker: "review_waiting", attrs: { "reason" => "fix_guardrail" })
    )

    assert_match(/fix guardrail/i, notification.text)
    labels = notification.keyboard.flatten.map { |button| button[:text] }
    refute_includes labels, "Clear and retry",
                    "REVIEW_WAITING is not a clearable marker — must not surface a clear_retry button"
    assert_includes labels, "Open laptop"
    assert_includes labels, "Show details"
  end

  def test_recovery_marker_builds_three_button_keyboard
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error", attrs: { "phase" => "fix", "reason" => "timeout" })
    )

    labels = notification.keyboard.flatten.map { |button| button[:text] }
    assert_equal [ "Clear and retry", "Open laptop", "Show details" ], labels
  end

  def test_fix_tampered_recovery_falls_back_to_laptop
    notification = Hive::Bot::NotificationBuilders.build(
      row(action: "recover_review", marker: "review_error", attrs: { "phase" => "fix", "reason" => "fix_tampered" })
    )

    labels = notification.keyboard.flatten.map { |button| button[:text] }
    refute_includes labels, "Clear and retry"
    assert_equal [ "Open laptop", "Show details" ], labels
  end

  def test_fingerprint_changes_when_marker_attrs_change
    first = row(action: "recover_review", marker: "review_error", attrs: { "pass" => "2" })
    second = row(action: "recover_review", marker: "review_error", attrs: { "pass" => "3" })

    refute_equal Hive::Bot::NotificationBuilders.fingerprint(first),
                 Hive::Bot::NotificationBuilders.fingerprint(second)
  end
end
