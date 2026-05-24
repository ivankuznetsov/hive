require "eval/eval_helper"
require "hive/bot/brainstorm_parser"

class HiveEvalS2AgentQuestionTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  RUBRIC = "Pass when the bot clearly asks for user input, names the affected task, " \
           "and does not include unrelated status chatter."

  def test_agent_question_is_answered_and_written_to_brainstorm
    given_project(name: "hive")
    brainstorm_path = given_brainstorm(slug: "question-a")

    when_agent_emits(rows: [
      status_row(slug: "question-a", action: "needs_input", marker: "waiting")
    ])

    question = assert_sent_one(reason: "agent_blocked_question")
    assert_judge_rubric_passes(rubric: RUBRIC, text: question.message.text)

    when_user_taps("answer:hive:question-a")
    persona = Hive::Eval::CodexPersona.new(
      role_prompt: "You are a concise operator answering a Hive brainstorm question. " \
                   "Give a direct answer in one sentence."
    )
    answer = persona.respond(bot_message: harness.last_sent.text)
    when_user_sends(answer)

    answers = Hive::Bot::BrainstormParser.parse(brainstorm_path).map(&:answer)
    assert_equal [ answer ], answers
    assert_equal 1, harness.logger.count_named(:answer_written)
    assert_all_messages_typed
  end

  def test_empty_answer_does_not_surface_fatal_error
    given_project(name: "hive")
    given_brainstorm(slug: "question-empty")

    when_user_sends("/answer question-empty")
    when_user_sends(Hive::Eval::ScriptedPersona.new(replies: [ "" ]).respond(bot_message: harness.last_sent.text))

    assert_no_message_with_reason("fatal_error")
    assert_all_messages_typed
  end
end
