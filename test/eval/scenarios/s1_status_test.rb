require "eval/eval_helper"

class HiveEvalS1StatusTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  RUBRIC = "Pass when the reply identifies blocking/actionable tasks, avoids progress noise, " \
           "and uses no more than two filler sentences."

  def test_status_query_sends_single_status_response
    given_project(name: "hive")
    rows = [
      status_row(slug: "needs-human", action: "needs_input", marker: "waiting"),
      status_row(slug: "running-agent", action: "agent_running", marker: "agent_working")
    ]
    harness.status_watcher.queue(rows: rows)

    when_user_sends("/status")

    assert_sent_count 1
    status = assert_sent_one(reason: "status_response")
    assert_all_messages_typed
    refute_proactive_status_response
    assert_judge_rubric_passes(rubric: RUBRIC, text: status.message.text)
  end

  def test_status_rows_without_user_request_do_not_emit_status_response
    given_project(name: "hive")

    when_agent_emits(rows: [
      status_row(slug: "running-agent", action: "agent_running", marker: "agent_working")
    ])

    assert_sent_count 0
    assert_no_message_with_reason("status_response")
  end
end
