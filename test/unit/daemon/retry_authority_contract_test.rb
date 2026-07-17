require "test_helper"

class RetryAuthorityContractTest < Minitest::Test
  RETIRED = %w[
    MAX_AUTO_RETRIES BACKOFF_SECOND_SEC TRANSIENT_BACKOFF_SCHEDULE
    ERROR_AUTO_RECOVERY_LIMIT REVIEW_ERROR_AUTO_RECOVERY_LIMIT
    TIMEOUT_RECOVERY_LIMIT ATTEMPT_LOSS_RECOVERY_LIMIT
  ].freeze

  def test_production_has_one_retry_authority_and_no_marker_clear_requeue_path
    sources = Dir["lib/hive/**/*.rb"].to_h { |path| [ path, File.read(path) ] }
    daemon_retry_sources = sources.select { |path, _| path.start_with?("lib/hive/daemon/") }

    RETIRED.each do |constant|
      offenders = daemon_retry_sources.select { |_path, body| body.include?(constant) }.keys
      assert_empty offenders, "#{constant} remains in #{offenders.join(', ')}"
    end
    healer_sources = daemon_retry_sources.select { |path, _| path.include?("healer") }
    refute healer_sources.values.any? { |body| body.include?("Markers.clear_current") }
    refute healer_sources.values.any? { |body| body.include?("write_request!") }

    recovery_surfaces = sources.select do |path, _body|
      path.match?(%r{lib/hive/(?:bot|web|tui|task_action)/})
    end
    direct_marker_retry = recovery_surfaces.select do |_path, body|
      body.match?(/\[\s*["']hive["']\s*,\s*["']markers["']\s*,\s*["']clear["']/)
    end
    assert_empty direct_marker_retry.keys,
                 "operator surfaces must route through `hive retry`, not marker clear: #{direct_marker_retry.keys.join(', ')}"

    authorization_writers = sources.select do |path, body|
      body.include?("DispatchAuthorization.new") && !path.end_with?("retry_coordinator.rb")
    end
    assert_empty authorization_writers.keys
    assert_includes sources.fetch("lib/hive/daemon/dispatcher.rb"), "dispatch_authorized_request"
    refute_includes sources.fetch("lib/hive/attempts/dispatcher.rb"), "def dispatch_successor"
  end
end
