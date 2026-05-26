require "eval/eval_helper"
require "hive/bot/brainstorm_parser"

# Full Telegram-perspective round-trip for the brainstorm Q&A flow.
#
# Compositionally covers the six invariants introduced by the operator-UX
# cleanup (PR #164):
#
#   1. status row → brainstorm_waiting notification fires with the right
#      single-button keyboard ([["Answer in chat"]])
#   2. Tapping the button triggers answerCallbackQuery on the Telegram side
#      (the spinner-fix invariant; legacy bot never called it)
#   3. start_answer reply names the actual question text instead of the
#      bare "Send Q1's answer" prompt
#   4. Each answer write triggers an auto-advance message that names the
#      next question and the "Reply with your answer" prompt
#   5. The final answer produces "Got QN." (no "send /done" prompt) and
#      auto-dispatches hive run because all questions are answered
#   6. conversation_store is cleared by the auto-dispatch path; /done still
#      works as a manual backstop but is no longer required
#
# Pure structural test — no Codex judge calls. Deterministic on every run.
class HiveEvalS6BrainstormRoundTripTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  SLUG = "experimental-260526-aaaa".freeze

  BRAINSTORM_CONTENT = <<~MARKDOWN.freeze
    ## Round 1

    ### Q1. Should we use SQLite or Postgres?

    ### A1.

    ### Q2. What is the auth model — sessions or tokens?

    ### A2.

    ### Q3. Where does the worker queue live?

    ### A3.

    ### Q4. What is the rollback story?

    ### A4.

    <!-- WAITING -->
  MARKDOWN

  ANSWERS = [ "Use Postgres for relational guarantees.",
              "Session cookies; tokens later if we add a mobile client.",
              "Sidekiq backed by Redis on the same VM as the API.",
              "Capistrano `cap deploy:rollback` plus a 24h DB snapshot." ].freeze

  def test_full_round_trip_from_status_row_through_done_dispatch
    # Daemon enabled keeps any incidental ready_to_X rows quiet; this scenario
    # focuses on needs_input + waiting (the agent_blocked_question alert path).
    given_project(name: "hive", daemon_enabled: true)
    brainstorm_path = given_brainstorm(slug: SLUG, content: BRAINSTORM_CONTENT)

    # --- Tick 1: status row fires the brainstorm_waiting notification ---
    when_agent_emits(rows: [
      status_row(slug: SLUG, action: "needs_input", marker: "waiting", stage: "2-brainstorm")
    ])
    alert = assert_sent_one(reason: "agent_blocked_question")
    assert_match(/Brainstorm questions are waiting/, alert.message.text)
    keyboard_labels = Array(alert.message.reply_markup).flatten.map { |btn| btn[:text] }
    assert_equal [ "Answer in chat" ], keyboard_labels,
                 "brainstorm-waiting keyboard must surface Answer in chat ONLY — no Open laptop, no Ask Codex"
    refute_includes keyboard_labels, "Open laptop"
    refute_includes keyboard_labels, "Ask Codex"

    # --- Tick 2: operator taps Answer in chat ---
    tap_update = when_user_taps("answer:hive:#{SLUG}")

    assert_equal 1, harness.telegram.answered_callbacks.length,
                 "every callback_query update must be acked exactly once via answerCallbackQuery " \
                 "(prevents the perpetual Telegram spinner)"
    ack = harness.telegram.answered_callbacks.first
    assert_equal "cbq-#{tap_update.update_id}", ack.callback_query_id,
                 "the ack must reference the same callback_query_id the inbound update carried"
    assert_nil ack.text, "ack must be silent (no toast)"

    # The start_answer reply must include the actual Q1 text, not a bare prompt.
    assert_match(/Q1:\s+Should we use SQLite or Postgres\?/, harness.last_sent.text)
    assert_match(/Reply with your answer/, harness.last_sent.text)

    # --- Ticks 3-5: answer Q1..Q3, asserting auto-advance to Q2..Q4 ---
    ANSWERS[0..2].each_with_index do |answer_text, idx|
      n = idx + 1
      when_user_sends(answer_text)

      reply = harness.last_sent.text
      assert_match(/Got Q#{n}\./, reply,
                   "auto-advance reply must acknowledge the answer we just wrote (Q#{n})")
      assert_match(/Q#{n + 1}:/, reply,
                   "auto-advance reply must include the next question header (Q#{n + 1})")
      assert_match(/Reply with your answer/, reply,
                   "auto-advance reply must prompt the operator to keep going")
    end

    # --- Tick 6: answer Q4 (last) ---
    when_user_sends(ANSWERS[3])
    final_reply = harness.last_sent.text
    assert_equal "Got Q4.", final_reply,
                 "final answer must produce a clean Got QN. ack — no 'send /done' prompt, " \
                 "no invented Q5"
    refute_match(/Q5:/, final_reply)
    refute_match(%r{send /done}, final_reply)

    # Auto-dispatch happened on the last answer; the conversation store is
    # cleared so /done is a no-op safety net but not required.
    assert_equal [ "hive", "run", SLUG, "--json" ], harness.child_supervisor.commands.last,
                 "all-answered must auto-dispatch hive run — operator does not need to send /done"
    state = harness.instance_variable_get(:@conversation_store)
                    .get(chat_id: Hive::Eval::FakeTelegram::DEFAULT_CHAT_ID)
    assert_nil state,
               "conversation_store must be cleared after auto-dispatch so a stale state can't " \
               "double-dispatch on a later message"

    # --- Disk-level assertion: every answer landed in brainstorm.md in order ---
    parsed_answers = Hive::Bot::BrainstormParser.parse(brainstorm_path).map(&:answer)
    assert_equal ANSWERS, parsed_answers,
                 "all four answers must be written to brainstorm.md in order by BrainstormAnswerWriter"

    # --- Logger-side assertion: four answer_written events fired ---
    assert_equal 4, harness.logger.count_named(:answer_written)

    # --- Full-flow contract assertions ---
    assert_all_messages_typed
    assert_no_duplicates(window_sec: 300)
    assert_proactive_rule
  end
end
