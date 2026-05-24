require "eval/eval_helper"

class HiveEvalS5StuckTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  def test_silent_agent_after_question_does_not_create_message_storm
    given_project(name: "hive")

    when_agent_emits(rows: [
      status_row(slug: "question-a", action: "needs_input", marker: "waiting")
    ])
    30.times do
      when_clock_advances(60)
      when_agent_emits(rows: [])
    end

    assert_sent_count 1
    assert_sent_one(reason: "agent_blocked_question")
    assert_all_messages_typed
    assert_proactive_rule
    assert_no_duplicates(window_sec: 300)
  end

  def test_idle_running_ticks_emit_no_messages
    given_project(name: "hive")

    30.times do |idx|
      when_agent_emits(rows: [
        status_row(slug: "running-#{idx}", action: "agent_running", marker: "agent_working")
      ])
      when_clock_advances(60)
    end

    assert_sent_count 0
    assert_all_messages_typed
  end
end
