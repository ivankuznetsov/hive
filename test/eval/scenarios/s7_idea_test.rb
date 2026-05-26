require "eval/eval_helper"

# Telegram-perspective contract for the `/idea` project-picker flow.
#
# Compositionally covers the invariants that the integration-tree router-
# only test (test/integration/bot/scenarios/s4_idea_test.rb) cannot reach:
#
#   1. /idea <text> emits exactly one Sent message with text "Pick a
#      project for the idea." and a keyboard listing every registered
#      project plus a "+ new project" row.
#   2. Tapping a project row:
#      - fires answerCallbackQuery exactly once (spinner ack)
#      - dispatches `hive new <project> <text> --json` via FakeChildSupervisor
#      - emits NO additional Sent message — regression guard for the
#        "drop dispatch chatter" change in fdebb64e
#   3. The next /idea invocation starts the previously-picked project
#      with the ★ marker per `project_keyboard` in slash_handlers.rb:94.
#   4. /idea with no text body replies with the usage hint and dispatches
#      nothing.
class HiveEvalS7IdeaTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  def test_idea_picker_shows_all_registered_projects_and_dispatches_hive_new
    given_project(name: "hive")
    given_project(name: "writero")

    when_user_sends("/idea fix the broken cron")

    assert_sent_count 1
    picker = harness.last_sent
    assert_equal "Pick a project for the idea.", picker.text

    rows = Array(picker.reply_markup)
    labels = rows.map { |row| Array(row).first[:text] }
    assert_equal [ "hive", "writero", "+ new project" ], labels,
                 "picker keyboard must list every registered project followed by + new project"

    hive_button = rows.first.first
    assert_match(/\Aidea_project:hive:[0-9a-f]{8}\z/, hive_button[:callback_data],
                 "project row callback_data must be idea_project:<name>:<token>")

    when_user_taps(hive_button[:callback_data])

    assert_equal [ "hive", "new", "hive", "fix the broken cron", "--json" ],
                 harness.child_supervisor.commands.last,
                 "tapping a project must dispatch hive new <project> <text> --json"

    assert_equal 1, harness.telegram.answered_callbacks.length,
                 "every callback_query update must be acked exactly once via answerCallbackQuery"

    # No extra Sent after the tap — this is the regression guard for
    # "Queued command pid=" / "Command completed" suppression. The picker
    # message is still the single Sent.
    assert_sent_count 1

    assert_all_messages_typed
    assert_no_duplicates(window_sec: 300)
    assert_proactive_rule
  end

  def test_idea_picker_marks_last_picked_project_with_star
    given_project(name: "hive")
    given_project(name: "writero")

    when_user_sends("/idea fix the broken cron")
    first_picker = harness.last_sent
    hive_row = Array(first_picker.reply_markup).first
    when_user_taps(hive_row.first[:callback_data])

    when_user_sends("/idea wire the dashboard")

    second_picker = harness.last_sent
    refute_equal first_picker.fingerprint, second_picker.fingerprint,
                 "second picker should have its own token; fingerprint must differ"
    labels = Array(second_picker.reply_markup).map { |row| Array(row).first[:text] }
    assert_equal [ "★ hive", "writero", "+ new project" ], labels,
                 "after a pick, the previous project is sorted first and starred"
  end

  def test_idea_without_text_replies_with_usage_hint
    given_project(name: "hive")

    when_user_sends("/idea")

    assert_sent_count 1
    assert_equal "Use /idea <text> to capture a new idea.", harness.last_sent.text
    assert_nil harness.last_sent.reply_markup,
               "the usage hint must not carry an inline keyboard"
    assert_empty harness.child_supervisor.commands,
                 "the usage hint must not dispatch any child command"
  end
end
