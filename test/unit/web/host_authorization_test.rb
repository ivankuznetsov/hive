require "test_helper"
require "hive/web/host_authorization"

class WebHostAuthorizationTest < Minitest::Test
  def test_disabled_loopback_policy_leaves_rails_host_defaults_unchanged
    assert_nil Hive::Web::HostAuthorization.allowed_hosts(environment: {})
  end

  def test_loopback_policy_allows_local_ranges_and_configured_origin
    hosts = Hive::Web::HostAuthorization.allowed_hosts(
      environment: {
        "HIVE_WEB_LOCAL_LOOPBACK" => "1",
        "HIVE_WEB_ORIGIN" => "https://hive.internal.example:8443/path"
      }
    )

    assert_includes hosts, "localhost"
    assert_includes hosts, "hive.internal.example"
    assert hosts.any? { |host| host.is_a?(IPAddr) && host.include?("127.0.0.1") }
    assert hosts.any? { |host| host.is_a?(IPAddr) && host.include?("::1") }
  end
end
