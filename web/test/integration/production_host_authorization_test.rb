require "test_helper"
require "open3"
require "rbconfig"

class ProductionHostAuthorizationTest < ActiveSupport::TestCase
  test "production host authorization admits arbitrary reverse proxy hosts" do
    script = <<~'RUBY'
      require "rack/mock"
      app = ActionDispatch::HostAuthorization.new(
        ->(_env) { [ 200, {}, [ "ok" ] ] },
        Rails.application.config.hosts
      )
      request = Rack::MockRequest.new(app)
      hosts = %w[
        localhost 127.0.0.1 [::1] hive.internal.example attacker.example
        hive.lan 192.168.1.42
      ]
      puts "hosts=#{hosts.map { |host| request.get("/", "HTTP_HOST" => host).status }.join(",")}"
      puts "origins=#{Rails.application.config.action_cable.allowed_request_origins.join(",")}"
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
    assert_includes stdout, "hosts=200,200,200,200,200,200,200"
    assert_includes stdout, "origins=https://hive.internal.example"
    refute_includes stdout + stderr, "Blocked hosts:"
  end
end
