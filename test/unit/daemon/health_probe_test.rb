require "test_helper"
require "hive/daemon/health_probe"

class HiveDaemonHealthProbeTest < Minitest::Test
  def test_publishes_external_availability_without_command_probe_api
    publisher = Hive::Daemon::HealthProbe.new(config: {}, env: { "TOKEN" => "secret" })
    signal = publisher.publish(
      category: :codex_auth, available: true,
      observed_at: Time.utc(2026, 7, 17, 12, 0, 0)
    )

    assert_equal true, signal.fetch(:available)
    assert_equal "availability_only", signal.fetch(:authority)
    refute_respond_to publisher, :probe
    refute_includes signal.to_s, "secret"
  end
end
