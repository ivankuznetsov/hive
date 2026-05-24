require "eval/eval_helper"

class HiveEvalS4ButtonTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  def test_inline_approve_button_dispatches_expected_command
    given_project(name: "hive")

    when_agent_emits(rows: [
      status_row(slug: "ship-a", stage: "7-artifacts", action: "ready_to_finalize", marker: "complete")
    ])
    button = harness.last_sent.reply_markup.flatten.find { |candidate| candidate[:text] == "Approve" }

    when_user_taps(button.fetch(:callback_data))

    assert_equal [ "hive", "finalize", "ship-a", "--from", "7-artifacts",
                   "--project", "hive", "--json" ], harness.child_supervisor.commands.last
    assert_match(/Queued command pid=/, harness.last_sent.text)
    assert_all_messages_typed
    assert_no_duplicates(window_sec: 300)
  end

  def test_unknown_callback_does_not_crash_or_emit_unclassified_message
    given_project(name: "hive")

    when_user_taps("unknown:callback:data")

    assert_sent_count 1
    assert_all_messages_typed
  end
end
