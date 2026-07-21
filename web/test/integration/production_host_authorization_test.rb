require "test_helper"
require "open3"
require "rbconfig"

class ProductionHostAuthorizationTest < ActiveSupport::TestCase
  test "production host authorization admits intended hosts and rejects others" do
    script = <<~'RUBY'
      require "rack/mock"
      app = ActionDispatch::HostAuthorization.new(
        ->(_env) { [ 200, {}, [ "ok" ] ] },
        Rails.application.config.hosts
      )
      request = Rack::MockRequest.new(app)
      hosts = %w[localhost 127.0.0.1 [::1] hive.internal.example attacker.example]
      puts hosts.map { |host| request.get("/", "HTTP_HOST" => host).status }.join(",")
    RUBY
    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "production",
        "SECRET_KEY_BASE_DUMMY" => "1",
        "HIVE_WEB_LOCAL_LOOPBACK" => "1",
        "HIVE_WEB_ORIGIN" => "https://hive.internal.example"
      },
      RbConfig.ruby, "bin/rails", "runner", script,
      chdir: Rails.root
    )

    assert status.success?, stderr
    assert_equal "200,200,200,200,403", stdout.lines.last&.strip
    assert_includes stdout + stderr, "Blocked hosts: attacker.example"
  end

  test "production host authorization permits LAN hosts when loopback mode is disabled" do
    script = <<~'RUBY'
      require "rack/mock"
      app = ActionDispatch::HostAuthorization.new(
        ->(_env) { [ 200, {}, [ "ok" ] ] },
        Rails.application.config.hosts
      )
      request = Rack::MockRequest.new(app)
      hosts = %w[hive.lan 192.168.1.42]
      puts hosts.map { |host| request.get("/", "HTTP_HOST" => host).status }.join(",")
    RUBY
    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "production",
        "SECRET_KEY_BASE_DUMMY" => "1",
        "HIVE_WEB_LOCAL_LOOPBACK" => nil,
        "HIVEBOX_LOCAL_LOOPBACK" => nil
      },
      RbConfig.ruby, "bin/rails", "runner", script,
      chdir: Rails.root
    )

    assert status.success?, stderr
    assert_equal "200,200", stdout.lines.last&.strip
    refute_includes stdout + stderr, "Blocked hosts:"
  end
end
