require "test_helper"
require "hive/daemon/health_signal"

class HiveDaemonHealthSignalTest < Minitest::Test
  def test_fingerprint_changes_only_with_supplied_availability_observation
    first = Hive::Daemon::HealthSignal.fingerprint(
      category: :codex_auth, available: false, source: "provider", observed_version: 1,
      env: { "TOKEN" => "one" }
    )
    same = Hive::Daemon::HealthSignal.fingerprint(
      category: :codex_auth, available: false, source: "provider", observed_version: 1,
      env: { "TOKEN" => "two" }
    )
    changed = Hive::Daemon::HealthSignal.fingerprint(
      category: :codex_auth, available: true, source: "provider", observed_version: 2
    )

    assert_equal first, same
    refute_equal first, changed
    refute_respond_to Hive::Daemon::HealthSignal, :changed_or_fallback?
  end
end
