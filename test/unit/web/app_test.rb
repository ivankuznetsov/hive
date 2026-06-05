require "test_helper"
require "rack/test"

class WebAppTest < Minitest::Test
  include Rack::Test::Methods
  include HiveTestHelper

  def app
    @app
  end

  def setup
    @tmp = Dir.mktmpdir("hive-web")
    @old_env = {
      "HIVE_HOME" => ENV["HIVE_HOME"],
      "HOME" => ENV["HOME"],
      "HIVEBOX_SESSION_SECRET" => ENV["HIVEBOX_SESSION_SECRET"]
    }
    ENV["HIVE_HOME"] = @tmp
    ENV["HOME"] = @tmp
    ENV["HIVEBOX_SESSION_SECRET"] = "x" * 64
    File.write(File.join(@tmp, "config.yml"), {
      "registered_projects" => [],
      "web" => {
        "github" => { "owner" => "alice", "client_id" => "client" }
      }
    }.to_yaml)
    require "hive/web/app"
    Hive::Web::App.reconfigure!
    @app = Hive::Web::App
  end

  def teardown
    @old_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.rm_rf(@tmp)
  end

  def test_health_is_public
    get "/health", {}, "HTTP_HOST" => "127.0.0.1"

    assert last_response.ok?
    assert_equal({ "ok" => true }, JSON.parse(last_response.body))
  end

  def test_root_redirects_to_login_when_unauthenticated
    get "/", {}, "HTTP_HOST" => "127.0.0.1"

    assert_equal 302, last_response.status
    assert_equal "http://127.0.0.1/login", last_response["Location"]
  end
end
