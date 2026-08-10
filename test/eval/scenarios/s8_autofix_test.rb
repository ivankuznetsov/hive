require "eval/eval_helper"

# Telegram-perspective contract for the 🔧 Autofix recovery callback.
#
# Compositionally covers:
#
#   1. A retryable recovery row (suggested_next_action.kind == "retry",
#      marker NOT in ALWAYS_MANUAL_MARKERS) emits a notification whose
#      keyboard is exactly [["🔧 Autofix"]] — no Show details, no Open
#      laptop, no other buttons.
#   2. The Autofix callback_data carries the durable marker_id guard.
#   3. Tapping the button:
#      - fires answerCallbackQuery exactly once (spinner ack)
#      - clears the inline keyboard on the originating message
#        (anti-double-tap)
#      - submits exactly one guarded request to RecoveryCoordinator
#      - renders the coordinator's canonical queued receipt
#   4. A row whose marker is in ALWAYS_MANUAL_MARKERS (execute_stale)
#      gets a "Show details"-only keyboard with no Autofix anywhere.
class HiveEvalS8AutofixTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  def test_autofix_keyboard_submits_one_coordinator_recovery
    given_project(name: "hive", daemon_enabled: true)

    when_agent_emits(rows: [
      status_row(
        slug: "stuck-260525-abcd",
        stage: "6-review",
        marker: "review_error",
        attrs: {
          "phase" => "fix", "pass" => "2",
          "marker_id" => "x"
        },
        action: "recover_review",
        diagnostic: { "suggested_next_action" => { "kind" => "retry" } }
      )
    ])

    alert = assert_sent_one(reason: "fatal_error")
    keyboard = Array(alert.message.reply_markup)
    labels = keyboard.flatten.map { |btn| btn[:text] }
    assert_equal [ "🔧 Autofix" ], labels,
                 "retryable recovery keyboard must be exactly 🔧 Autofix"

    autofix_cb = keyboard.flatten.first[:callback_data]
    assert_equal(
      "autofix:hive:stuck-260525-abcd:6-review:review_error:marker_id=x",
      autofix_cb,
      "callback_data must carry the durable recovery generation"
    )

    sent_before_tap = harness.sent.length

    when_user_taps(autofix_cb)

    assert_equal 1, harness.telegram.answered_callbacks.length,
                 "tap must fire answerCallbackQuery exactly once"

    assert_equal(
      1,
      harness.telegram.edits.length,
      "tap must clear the originating keyboard exactly once; sent=#{harness.sent.map(&:text).inspect}"
    )
    assert_nil harness.telegram.edits.first.reply_markup,
               "edit_message_reply_markup with nil clears the keyboard"

    assert_empty harness.dispatched_commands,
                 "adapters must not clear markers or dispatch a second recovery mechanism"
    recovery = harness.dispatch_request_writer.recoveries.fetch(0)
    assert_equal "hive", recovery.fetch(:project)
    assert_equal "stuck-260525-abcd", recovery.fetch(:row).slug
    assert_equal "bot", recovery.fetch(:requestor)
    assert_equal sent_before_tap + 1, harness.sent.length
    assert_match(/Recovery queued/, harness.last_sent.text)

    assert_all_messages_typed
    assert_no_duplicates(window_sec: 300)
  end

  def test_manual_only_recovery_keyboard_is_show_details_with_no_autofix
    given_project(name: "hive", daemon_enabled: true)

    when_agent_emits(rows: [
      status_row(
        slug: "stale-260525-abcd",
        stage: "4-execute",
        marker: "execute_stale",
        attrs: {},
        action: "recover_review",
        diagnostic: { "suggested_next_action" => { "kind" => "retry" } }
      )
    ])

    alert = assert_sent_one(reason: "fatal_error")
    keyboard = Array(alert.message.reply_markup)
    labels = keyboard.flatten.map { |btn| btn[:text] }
    assert_equal [ "Show details" ], labels,
                 "ALWAYS_MANUAL_MARKERS must surface Show details only — no Autofix even if suggested_next_action says retry"
    refute(labels.any? { |label| label.include?("Autofix") },
           "manual-only marker must not expose Autofix anywhere on the keyboard")
  end
end
