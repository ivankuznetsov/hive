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

  def test_snapshot_without_an_installer_reports_unsupported_manager
    result = Hive::Web::ServiceStatus.snapshot(
      installer: nil,
      config: config,
      probe: ->(*) { flunk "an unavailable manager must not trigger a health probe" }
    )

    assert_equal "unsupported", result["platform"]
    assert_equal false, result["service_manager_available"]
    assert_equal false, result["ready"]
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

  def test_snapshot_waits_for_launchd_job_to_start_before_probing_health
    states = [
      {
        "platform" => "macos", "unit_path" => "/unit", "service_installed" => true,
        "service_enabled" => true, "service_running" => false, "service_manager_available" => true
      },
      {
        "platform" => "macos", "unit_path" => "/unit", "service_installed" => true,
        "service_enabled" => true, "service_running" => true, "service_manager_available" => true
      }
    ]
    samples = 0
    rich_installer = Object.new
    rich_installer.define_singleton_method(:service_lifecycle_state) do
      samples += 1
      states.fetch([ samples - 1, states.length - 1 ].min)
    end

    result = Hive::Web::ServiceStatus.snapshot(
      installer: rich_installer,
      config: config,
      probe: ->(*) { true },
      wait_for_running: true,
      attempts: 2,
      interval: 0,
      sleeper: ->(*) { }
    )

    assert_equal 2, samples
    assert result["service_running"]
    assert result["ready"]
    assert_equal "ready", result["readiness"]
  end

  def test_snapshot_stops_waiting_when_service_becomes_disabled
    states = [
      {
        "platform" => "macos", "unit_path" => "/unit", "service_installed" => true,
        "service_enabled" => true, "service_running" => false, "service_manager_available" => true
      },
      {
        "platform" => "macos", "unit_path" => "/unit", "service_installed" => true,
        "service_enabled" => false, "service_running" => false, "service_manager_available" => true
      }
    ]
    samples = 0
    sleeps = []
    rich_installer = Object.new
    rich_installer.define_singleton_method(:service_lifecycle_state) do
      state = states.fetch([ samples, states.length - 1 ].min)
      samples += 1
      state
    end

    result = Hive::Web::ServiceStatus.snapshot(
      installer: rich_installer,
      config: config,
      wait_for_running: true,
      attempts: 3,
      interval: 0.1,
      sleeper: ->(duration) { sleeps << duration }
    )

    assert_equal 2, samples
    assert_equal [ 0.1 ], sleeps
    assert_equal false, result["service_enabled"]
    assert_equal "disabled", result["readiness"]
  end

  def test_read_only_status_snapshot_probes_health_once
    starts = 0
    unavailable = response(Net::HTTPBadGateway, "not ready")
    with_replaced_singleton_method(Net::HTTP, :start, lambda { |*_args, **_kwargs, &block|
      starts += 1
      http = Object.new
      http.define_singleton_method(:get) { |_path, _headers| unavailable }
      block.call(http)
    }) do
      result = Hive::Web::ServiceStatus.snapshot(
        installer: installer(running_state), config: config, interval: 0
      )

      assert_equal "active_not_ready", result["readiness"]
    end

    assert_equal 1, starts
  end

  def test_setup_install_snapshot_retains_configured_health_retry_window
    starts = 0
    unavailable = response(Net::HTTPBadGateway, "not ready")
    with_replaced_singleton_method(Net::HTTP, :start, lambda { |*_args, **_kwargs, &block|
      starts += 1
      http = Object.new
      http.define_singleton_method(:get) { |_path, _headers| unavailable }
      block.call(http)
    }) do
      result = Hive::Web::ServiceStatus.snapshot(
        installer: installer(running_state), config: config,
        wait_for_running: true, attempts: 3, interval: 0
      )

      assert_equal "active_not_ready", result["readiness"]
    end

    assert_equal 3, starts
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

  def running_state
    {
      "platform" => "linux", "unit_path" => "/unit", "service_installed" => true,
      "service_enabled" => true, "service_running" => true, "service_manager_available" => true
    }
  end

  def response(type, body)
    value = type.new("1.1", type == Net::HTTPOK ? "200" : "502", type.name)
    value.define_singleton_method(:body) { body }
    value
  end
end
