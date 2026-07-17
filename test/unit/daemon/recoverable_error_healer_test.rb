require "test_helper"
require "hive/daemon/recoverable_error_healer"
require "hive/daemon/status_consumer"

class HiveDaemonRecoverableErrorHealerTest < Minitest::Test
  def test_observes_diagnostics_without_clearing_or_probing
    events = []
    logger = Object.new
    logger.define_singleton_method(:event) { |name, **attrs| events << [ name, attrs ] }
    row = Hive::Daemon::StatusConsumer::Row.new(
      project: "p", slug: "s", stage: "4-execute", marker: "error",
      marker_attrs: { "reason" => "implementer_failed", "message" => "401 missing bearer auth" }
    )
    healer = Hive::Daemon::RecoverableErrorHealer.new(
      logger: logger, health_probe: -> { flunk("must not probe") },
      request_queue: -> { flunk("must not dispatch") }
    )

    healer.heal([ row ], now: Time.utc(2026, 7, 17))

    event = events.fetch(0)
    assert_equal :terminal_diagnostic_observed, event.fetch(0)
    assert_equal "codex_auth", event.fetch(1).fetch(:code)
    assert_equal "coordinator", event.fetch(1).fetch(:route)
  end
end
