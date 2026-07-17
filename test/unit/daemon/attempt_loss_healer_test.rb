require "test_helper"
require "hive/daemon/stale_agent_healer"

class AttemptLossHealerTest < Minitest::Test
  def test_repeated_loss_observations_only_invoke_durable_preservation_and_reporter
    attempts = [ Object.new, Object.new ]
    processed = []
    reported = []
    processor = Object.new
    processor.define_singleton_method(:process) { |attempt, now:| processed << [ attempt, now ] }
    reporter = Object.new
    reporter.define_singleton_method(:observe) { |attempt| reported << attempt }
    controller = Object.new
    controller.define_singleton_method(:running_task?) { |**| false }
    logger = Object.new
    logger.define_singleton_method(:event) { |*| }
    healer = Hive::Daemon::StaleAgentHealer.new(
      controller: controller, logger: logger,
      lost_outcome_processor: processor, failure_reporter: reporter,
      attempt_dispatcher: -> { flunk("successor dispatch is forbidden") }
    )
    now = Time.utc(2026, 7, 17)

    healer.heal_attempt_losses(attempts, now: now)

    assert_equal attempts, processed.map(&:first)
    assert_equal attempts, reported
  end
end
