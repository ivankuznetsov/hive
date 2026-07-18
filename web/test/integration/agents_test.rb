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

  test "operator-ward agent (codex) keeps polling and shows no paste-back form" do
    sign_in!(login: "alice")
    seed_session("sess-codex", agent: "codex", url: "https://auth.openai.com/codex/device",
                 output: "Enter this code: Q0F3-V1IO7", done: false)

    get agent_login_status_path("codex", "sess-codex")

    assert_response :success
    assert_match "https://auth.openai.com/codex/device", response.body
    assert_match "updates automatically", response.body
    assert_match 'data-controller="poll"', response.body,
                 "a poll-type agent must keep refreshing until the CLI exits"
    assert_no_match(/Complete login/, response.body,
                    "operator-ward agents must not show a paste-the-code form")
  end

  test "agents page offers the supported Grok device login" do
    sign_in!(login: "alice")

    get agents_path

    assert_response :success
    assert_select "form[action='#{agent_login_path("grok")}'] button", text: "Start login"
    assert_select ".agent-card", { text: /grok.*Uses the token form below/m, count: 0 },
                  "Grok has a first-class device flow and must not be described as token-only"
  end

  test "operator-ward agent (grok) keeps polling and shows no paste-back form" do
    sign_in!(login: "alice")
    seed_session("sess-grok", agent: "grok", url: "https://accounts.x.ai/device",
                 output: "Enter this code: GROK-CODE", done: false)

    get agent_login_status_path("grok", "sess-grok")

    assert_response :success
    assert_match "https://accounts.x.ai/device", response.body
    assert_match "updates automatically", response.body
    assert_match 'data-controller="poll"', response.body
    assert_no_match(/Complete login/, response.body)
  end

  test "operator-ward agent shows success and stops polling once done" do
    sign_in!(login: "alice")
    seed_session("sess-done", agent: "codex", url: "https://auth.openai.com/codex/device",
                 output: "done", done: true)

    get agent_login_status_path("codex", "sess-done")

    assert_response :success
    assert_match "is now logged in", response.body
    assert_no_match(/data-controller="poll"/, response.body,
                    "polling must stop once the login is done")
  end

  test "paste-back agent (claude) keeps the code form and stops polling at the URL" do
    sign_in!(login: "alice")
    seed_session("sess-claude", agent: "claude", url: "https://claude.ai/device",
                 output: "paste the code", done: false)

    get agent_login_status_path("claude", "sess-claude")

    assert_response :success
    assert_match "Complete login", response.body, "paste-back agents keep the code form"
    assert_no_match(/data-controller="poll"/, response.body,
                    "a paste-back agent stops polling once its URL is shown")
  end

  private

  def seed_session(id, agent:, url:, output:, done:, error: nil)
    session = Hive::Web::AgentsAuth::Session.new(
      id: id, agent: agent, url: url, output: +output, done: done, error: error
    )
    AgentsController.agents_auth.instance_variable_get(:@sessions)[id] = session
  end
end
