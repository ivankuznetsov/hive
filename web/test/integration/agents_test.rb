require "test_helper"

# Regression guard for the Agents login-status 500. The CLI relay buffers
# raw ASCII-8BIT PTY bytes; rendering them into the UTF-8 `<pre>` view raised
# Encoding::CompatibilityError (a 500 on /agents/<agent>/login/<id>). The lib
# suite never caught it — its only direct `output_for` test used clean ASCII
# and the login fakes echoed clean text, and nothing drove the controller +
# view. This exercises the exact layer that broke: a binary-output session
# rendered through the real view.
class AgentsTest < ActionDispatch::IntegrationTest
  teardown do
    # AgentsController.agents_auth is a class-memoized process singleton —
    # drop it so a seeded session can't leak into another test.
    AgentsController.instance_variable_set(:@agents_auth, nil)
  end

  test "login_status renders binary CLI output as 200, not a 500" do
    sign_in!(login: "alice")

    auth = AgentsController.agents_auth
    # Raw PTY bytes: ANSI clear-line, a box glyph, and a lone UTF-8
    # continuation byte (a multibyte char split across a readpartial
    # boundary) — invalid UTF-8, the shape that crashed the <pre> view.
    binary = +"".b
    binary << "\e[2K".b << "█".b << " Open https://example.com/auth ".b << "\xE2".b
    session = Hive::Web::AgentsAuth::Session.new(
      id: "sess-bin", agent: "claude",
      output: binary, url: "https://example.com/auth", done: false
    )
    auth.instance_variable_get(:@sessions)["sess-bin"] = session

    get agent_login_status_path("claude", "sess-bin")

    assert_response :success
    assert_match "https://example.com/auth", response.body,
                 "the authorize URL must render so the operator can finish login"
  end
end
