require "eval/eval_helper"

class HiveEvalFakeTelegramTest < Minitest::Test
  def test_records_sent_payloads_and_fingerprints
    telegram = Hive::Eval::FakeTelegram.new(now: -> { Time.utc(2026, 5, 24, 8, 0, 0) })
    keyboard = [ [ { text: "Approve", callback_data: "approve:plan:hive:slug:2-brainstorm" } ] ]

    telegram.send_message(chat_id: 12345, text: "Ready", reply_markup: keyboard, parse_mode: :markdown)

    sent = telegram.sent.fetch(0)
    assert_equal 12345, sent.chat_id
    assert_equal "Ready", sent.text
    assert_equal keyboard, sent.reply_markup
    assert_equal :markdown, sent.parse_mode
    assert_match(/\A[0-9a-f]{64}\z/, sent.fingerprint)
  end

  def test_queues_text_and_callback_updates
    telegram = Hive::Eval::FakeTelegram.new
    telegram.inject_update(text: "/status", update_id: 10)
    telegram.tap_button(callback_data: "details:hive:slug", update_id: 11, message_id: 3)

    updates = telegram.poll_updates(timeout: 0, since_update_id: 10)

    assert_equal [ 10, 11 ], updates.map(&:update_id)
    assert_equal "/status", updates.first.text
    assert_equal "details:hive:slug", updates.last.callback_data
    assert_equal 3, updates.last.message_id
  end
end
