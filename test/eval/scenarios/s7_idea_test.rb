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
#      - does NOT commit yet; it opens the file collector ("Send any files
#        now, or press Done.") with a Done/Skip keyboard. The commit fires
#        only when Done/Skip is tapped (plan Risk 1 — commit moved off the
#        project tap onto the Done/Skip lifecycle).
#   3. Tapping Done commits the idea (one "Captured your idea in <project>"
#      Sent message) and dispatches nothing through the child supervisor —
#      idea capture runs Hive::Commands::New in-process, not as a child.
#   4. The next /idea invocation starts the previously-picked project
#      with the ★ marker per `project_keyboard` in slash_handlers.rb.
#   5. /idea with no text body opens text capture ("Send the idea text in
#      your next message.") and dispatches nothing.
class HiveEvalS7IdeaTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  def test_idea_picker_shows_all_registered_projects_then_done_commits
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

    assert_empty harness.dispatched_commands,
                 "tapping a project must NOT dispatch a command — commit waits for Done/Skip"

    collector = harness.last_sent
    assert_match(/Send any files now/, collector.text,
                 "tapping a project opens the file collector before commit")
    done_button = Array(collector.reply_markup).flatten.detect { |button| button[:text] == "Done" }
    refute_nil done_button, "collector keyboard must expose Done"
    assert_match(/\Aidea_done:[0-9a-f]{8}\z/, done_button[:callback_data],
                 "Done callback_data must be idea_done:<token>")

    assert_equal 1, harness.telegram.answered_callbacks.length,
                 "every callback_query update must be acked exactly once via answerCallbackQuery"

    when_user_taps(done_button[:callback_data])

    assert_match(/Captured your idea in hive/, harness.last_sent.text,
                 "tapping Done must commit the idea and confirm capture")
    assert_empty harness.dispatched_commands,
                 "idea commit runs in-process (Hive::Commands::New), never as a dispatched command"

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

  def test_idea_without_text_starts_text_capture
    given_project(name: "hive")

    when_user_sends("/idea")

    assert_sent_count 1
    assert_equal "Send the idea text in your next message.", harness.last_sent.text
    assert_nil harness.last_sent.reply_markup,
               "the text-capture prompt must not carry an inline keyboard"
    assert_empty harness.dispatched_commands,
                 "the text-capture prompt must not dispatch any command"
  end
end
