require "test_helper"
require_relative "../../support/web_session_helper"
require "json"

# U3 HTTP wiring: the /agents routes must render login status, spawn the CLI
# login PTY, poll for the authorize URL, relay a pasted code, and persist a pi
# token — all behind the CSRF gate. These drive the *real* AgentsAuth against a
# fake `claude` on PATH (no real provider handshake) so the route bodies and
# their session-view helper are exercised end to end at the HTTP layer.
class WebAgentsRoutesTest < Minitest::Test
  include HiveTestHelper
  include WebSessionHelper

  AUTH_URL = "https://login.example/oauth?challenge=abc123".freeze

  def install_fake_claude(bin_dir)
    path = File.join(bin_dir, "claude")
    File.write(path, <<~SH)
      #!/usr/bin/env bash
      echo "Open #{AUTH_URL} to authenticate"
      read -r code
      if [ -n "$code" ]; then
        echo "token stored"
        exit 0
      fi
      exit 1
    SH
    FileUtils.chmod(0o755, path)
  end

  def with_box
    with_tmp_global_config do |home|
      bin_dir = File.join(home, "bin")
      FileUtils.mkdir_p(bin_dir)
      install_fake_claude(bin_dir)
      with_env(
        "HOME" => home,
        "PATH" => [ bin_dir, ENV.fetch("PATH", "") ].join(File::PATH_SEPARATOR)
      ) do
        boot_web_app
        login!
        yield(home)
      end
    end
  end

  def test_agents_page_lists_login_status
    with_box do |_home|
      get "/agents", {}, "HTTP_HOST" => "127.0.0.1"

      assert last_response.ok?
      assert_includes last_response.body, "Agents"
      assert_includes last_response.body, "Not logged in"
    end
  end

  def test_login_start_poll_and_complete_round_trip
    with_box do |_home|
      token = csrf_token_from("/agents")

      post "/agents/claude/login/start",
           { "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"
      assert last_response.ok?, "starting a login renders the session view (status #{last_response.status})"

      session_id = last_response.body[/login\/([0-9a-f]{16})/, 1] ||
                   last_response.body[/value="([0-9a-f]{16})"/, 1]
      assert session_id, "the rendered page must carry the new session id"

      # The poll route re-renders the same page (URL may already be present).
      get "/agents/claude/login/#{session_id}", {}, "HTTP_HOST" => "127.0.0.1"
      assert last_response.ok?
      assert_includes last_response.body, AUTH_URL

      complete_token = last_response.body[/name="authenticity_token" value="([^"]+)"/, 1]
      post "/agents/claude/login/complete",
           { "session_id" => session_id, "code" => "pasted-code", "authenticity_token" => complete_token },
           "HTTP_HOST" => "127.0.0.1"
      assert last_response.redirect?, "completing a login redirects back to /agents"
      assert_equal "http://127.0.0.1/agents", last_response["Location"]
    end
  end

  def test_login_poll_unknown_session_404s
    with_box do |_home|
      get "/agents/claude/login/deadbeefdeadbeef", {}, "HTTP_HOST" => "127.0.0.1"

      assert_equal 404, last_response.status
      assert_includes last_response.body, "unknown login session"
    end
  end

  def test_pi_token_persists_credentials
    with_box do |home|
      token = csrf_token_from("/agents")

      post "/agents/pi/token",
           { "token_json" => JSON.generate("OPENAI_API_KEY" => "sk-test"), "authenticity_token" => token },
           "HTTP_HOST" => "127.0.0.1"

      assert last_response.redirect?, "a valid pi token saves and redirects"
      auth_path = File.join(home, ".pi", "agent", "auth.json")
      assert File.file?(auth_path), "the pi token must be persisted to ~/.pi/agent/auth.json"
      assert_equal({ "OPENAI_API_KEY" => "sk-test" }, JSON.parse(File.read(auth_path)))
    end
  end
end
