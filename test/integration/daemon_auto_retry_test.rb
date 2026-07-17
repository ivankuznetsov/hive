require "test_helper"
require "hive/daemon/recoverable_error_healer"
require "hive/daemon/status_consumer"

class DaemonAutoRetryTest < Minitest::Test
  include HiveTestHelper

  def test_terminal_auth_marker_is_diagnostic_only_and_never_cleared_or_probed
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      Hive::Markers.set(
        state_file, :error,
        reason: "implementer_failed", provider: "codex",
        message: "401 missing bearer auth"
      )
      marker = Hive::Markers.current(state_file)
      row = Hive::Daemon::StatusConsumer::Row.new(
        project: "p", slug: "s", stage: "4-execute", marker: "error",
        marker_attrs: marker.attrs, folder: dir, state_file: state_file
      )
      events = []
      logger = Object.new
      logger.define_singleton_method(:event) { |name, **attrs| events << [ name, attrs ] }
      healer = Hive::Daemon::RecoverableErrorHealer.new(
        logger: logger, health_probe: -> { flunk("provider probe is forbidden") },
        request_queue: -> { flunk("direct redispatch is forbidden") }
      )

      10.times { healer.heal([ row ], now: Time.utc(2026, 7, 17)) }

      current = Hive::Markers.current(state_file)
      assert_equal :error, current.name
      assert_equal marker.attrs, current.attrs
      assert events.all? { |name, attrs| name == :terminal_diagnostic_observed && attrs[:route] == "coordinator" }
    end
  end
end
