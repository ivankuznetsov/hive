require "eval/eval_helper"

class HiveEvalReasonClassifierTest < Minitest::Test
  include Hive::Eval::ScenarioSupport

  def test_classifies_row_based_notifications
    question = message_for(row: status_row(action: "needs_input", marker: "waiting"))
    ready = message_for(row: status_row(action: "ready_to_finalize", marker: "complete"))
    fatal = message_for(row: status_row(action: "error", marker: "review_error"))

    reasons = classify(question, ready, fatal).map(&:reason)

    assert_equal %w[agent_blocked_question task_finished fatal_error], reasons
  end

  def test_classifies_handler_replies
    status = message_for(source: :handler, intent: :slash_status, text: "1 active task")
    answer = message_for(source: :handler, intent: :callback_answer, text: "Answer mode started for slug-a.")
    ack = message_for(source: :handler, intent: :callback_approve, text: "Queued command pid=20001")

    reasons = classify(status, answer, ack).map(&:reason)

    assert_equal %w[status_response agent_blocked_question status_response], reasons
  end

  def test_contract_reports_unclassified_messages
    harness.telegram.send_message(chat_id: 12345, text: "heartbeat: still alive")

    error = assert_raises(Minitest::Assertion) { assert_all_messages_typed }

    assert_match(/UNCLASSIFIED/, error.message)
    assert_match(/heartbeat/, error.message)
  end

  def test_contract_detects_duplicate_reason_payload_within_window
    2.times do
      harness.telegram.send_message(chat_id: 12345, text: "1 active task")
      harness.sent.last.source = :handler
      harness.sent.last.intent = :slash_status
    end

    error = assert_raises(Minitest::Assertion) { assert_no_duplicates(window_sec: 300) }

    assert_match(/duplicate Telegram payloads/, error.message)
  end

  private

  def classify(*messages)
    Hive::Eval::ReasonClassifier.new(messages: messages).classify_all
  end

  def message_for(text: "message", row: nil, source: :status_row, intent: nil)
    Hive::Eval::FakeTelegram::Sent.new(
      chat_id: 12345,
      text: text,
      reply_markup: nil,
      parse_mode: nil,
      t: Time.utc(2026, 5, 24, 8, 0, 0),
      fingerprint: Hive::Eval::FakeTelegram.payload_fingerprint(text: text, reply_markup: nil),
      source: source,
      row: row,
      intent: intent
    )
  end
end
