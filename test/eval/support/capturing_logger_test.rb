require "eval/eval_helper"

class HiveEvalCapturingLoggerTest < Minitest::Test
  def test_captures_events_in_order_with_attrs
    logger = Hive::Eval::CapturingLogger.new(now: -> { Time.utc(2026, 5, 24, 8, 0, 0) })

    logger.event(:notification_sent, project: "hive", slug: "slug-a", marker: "waiting")
    logger.event(:send_failure, chat_id: 12345, error_class: "Boom")
    logger.event(:answer_written, slug: "slug-a", question_n: 1)

    assert_equal %i[notification_sent send_failure answer_written], logger.events.map(&:name)
    assert_equal 1, logger.count_named(:send_failure)
    assert_equal [ "slug-a" ], logger.events_with(:answer_written, question_n: 1).map { |event| event.attrs[:slug] }
  end

  def test_harness_uses_capturing_logger_for_real_supervisor_events
    harness = Hive::Eval::Harness.new
    row = Hive::Bot::StatusWatcher::Row.new(
      project: "hive",
      slug: "need-answer",
      stage: "2-brainstorm",
      marker: "waiting",
      attrs: {},
      action: "needs_input",
      action_label: "needs input"
    )
    harness.status_watcher.queue(rows: [ row ])

    harness.when_user_sends("/status")

    assert_equal 1, harness.logger.count_named(:update_received)
    assert_equal "slash_status", harness.logger.events_named(:update_received).first.attrs[:intent]
  end
end
