require "test_helper"
require "hive/web/service_status"

class WebServiceStatusTest < Minitest::Test
  include HiveTestHelper

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

  def test_snapshot_advertises_environment_origin_but_probes_local_service
    state = {
      "platform" => "linux", "unit_path" => "/unit", "service_installed" => true,
      "service_enabled" => true, "service_running" => true, "service_manager_available" => true
    }
    probed = nil
    result = Hive::Web::ServiceStatus.snapshot(
      installer: installer(state), config: config,
      environment: { "HIVE_WEB_ORIGIN" => "https://hive.example.test" },
      probe: ->(url) { probed = url; true }
    )

    assert_equal "https://hive.example.test", result["url"]
    assert_equal "http://127.0.0.1:4567/health", probed
  end

  def test_canonical_origin_precedes_legacy_alias
    environment = {
      "HIVE_WEB_ORIGIN" => "https://canonical.example",
      "HIVEBOX_ORIGIN" => "https://legacy.example"
    }

    assert_equal "https://canonical.example",
                 Hive::Web::ServiceStatus.effective_url(config, environment: environment)
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

  def test_snapshot_prefers_rich_lifecycle_state
    state = {
      "platform" => "linux", "unit_path" => "/unit", "service_installed" => false,
      "service_enabled" => false, "service_running" => false, "service_manager_available" => true
    }
    rich_installer = Object.new
    rich_installer.define_singleton_method(:service_lifecycle_state) { state }
    rich_installer.define_singleton_method(:service_state) { flunk "legacy state must not be used" }

    result = Hive::Web::ServiceStatus.snapshot(installer: rich_installer, config: config)

    assert_equal "not_installed", result["readiness"]
  end

  def test_disabled_and_active_not_ready_are_distinct
    base = {
      "service_manager_available" => true,
      "service_installed" => true,
      "service_enabled" => false,
      "service_running" => false
    }
    assert_equal "disabled", Hive::Web::ServiceStatus.readiness_for(base, "http://127.0.0.1:4567")

    active = base.merge("service_enabled" => true, "service_running" => true)
    assert_equal "active_not_ready",
                 Hive::Web::ServiceStatus.readiness_for(active, "http://127.0.0.1:4567", probe: ->(*) { false })
  end

  def test_invalid_origin_reports_invalid_url
    active = {
      "service_manager_available" => true,
      "service_installed" => true,
      "service_enabled" => true,
      "service_running" => true
    }

    assert_equal "invalid_url", Hive::Web::ServiceStatus.readiness_for(active, "http://[")
  end

  def test_ready_retries_then_accepts_healthy_json
    responses = [ response(Net::HTTPBadGateway, "not-json"), response(Net::HTTPOK, '{"ok":true}') ]
    starts = 0

    with_replaced_singleton_method(Net::HTTP, :start, lambda { |*_args, **_kwargs, &block|
      starts += 1
      http = Object.new
      current = responses.shift
      http.define_singleton_method(:get) { |_path, _headers| current }
      block.call(http)
    }) do
      assert Hive::Web::ServiceStatus.ready?("http://127.0.0.1:4567/health", attempts: 2, interval: 0)
    end

    assert_equal 2, starts
  end

  def test_ready_retries_transport_errors_then_returns_false
    with_replaced_singleton_method(Net::HTTP, :start, ->(*_args, **_kwargs) { raise SocketError, "offline" }) do
      refute Hive::Web::ServiceStatus.ready?("http://127.0.0.1:4567/health", attempts: 2, interval: 0)
    end
  end

  def test_ready_rejects_invalid_uri
    refute Hive::Web::ServiceStatus.ready?("http://[", attempts: 1, interval: 0)
  end

  private

  def response(type, body)
    value = type.new("1.1", type == Net::HTTPOK ? "200" : "502", type.name)
    value.define_singleton_method(:body) { body }
    value
  end
end
