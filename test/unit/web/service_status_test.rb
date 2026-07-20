require "test_helper"
require "hive/web/service_status"

class WebServiceStatusTest < Minitest::Test
  def installer(state)
    Object.new.tap { |value| value.define_singleton_method(:service_state) { state } }
  end

  def config
    { "bind" => "127.0.0.1", "port" => 4567, "origin" => "http://127.0.0.1:4567" }
  end

  def test_running_service_reports_ready_only_after_health_probe
    state = {
      "platform" => "linux", "unit_path" => "/unit", "service_installed" => true,
      "service_enabled" => true, "service_running" => true, "service_manager_available" => true
    }
    result = Hive::Web::ServiceStatus.snapshot(
      installer: installer(state), config: config, probe: ->(url) { url.end_with?("/health") }
    )

    assert_equal "http://127.0.0.1:4567", result["url"]
    assert_equal true, result["ready"]
    assert_equal "ready", result["readiness"]
  end

  def test_inactive_service_does_not_probe_or_claim_readiness
    state = {
      "platform" => "linux", "unit_path" => "/unit", "service_installed" => true,
      "service_enabled" => true, "service_running" => false, "service_manager_available" => true
    }
    result = Hive::Web::ServiceStatus.snapshot(
      installer: installer(state), config: config, probe: ->(*) { flunk "inactive service must not be probed" }
    )

    assert_equal false, result["ready"]
    assert_equal "inactive", result["readiness"]
  end

  def test_manager_unavailable_is_distinct_from_inactive
    state = {
      "platform" => "linux", "unit_path" => "/unit", "service_installed" => true,
      "service_enabled" => false, "service_running" => false, "service_manager_available" => false
    }

    result = Hive::Web::ServiceStatus.snapshot(installer: installer(state), config: config)

    assert_equal "manager_unavailable", result["readiness"]
  end
end
