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
    AgentsController.instance_variable_set(:@agent_skills, nil)
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

  test "managed skill health is explicit and checked only for the selected project" do
    project = register_skill_project("agent-health-app")
    calls = []
    rows = [
      skill_row(health: "healthy", agent: "claude", capability: "ce-brainstorm"),
      skill_row(health: "missing", agent: "codex", capability: "wiki-plan"),
      skill_row(health: "conflicting", agent: "claude", capability: "ce-code-review")
    ]
    install_agent_skills_fake(
      inspect: lambda do |entry|
        calls << entry.fetch("name")
        rows
      end
    )
    sign_in!(login: "alice")

    get agents_path
    assert_response :success
    assert_empty calls, "opening Agents must not synchronously inventory every registered project's CLIs"
    assert_select "select[name='project'] option[value='#{project}']"

    get agents_path, params: { project: project }
    assert_response :success
    assert_equal [ project ], calls
    assert_select "[data-skill-health='healthy']", text: /ce-brainstorm/
    assert_select "[data-skill-health='missing']", text: /wiki-plan/
    assert_select "[data-skill-health='conflicting']", text: /ce-code-review/
    assert_select "form[action='#{agent_skills_repair_path}'] input[name='consent'][value='repair_managed_skills']"
    assert_match "Conflicting and custom skills stay untouched", response.body
  end

  test "managed skill repair requires explicit browser consent and rechecks the project" do
    project = register_skill_project("agent-repair-app")
    repairs = []
    rows = [ skill_row(health: "healthy") ]
    install_agent_skills_fake(
      inspect: ->(_entry) { rows },
      repair: lambda do |entry|
        repairs << entry.fetch("name")
        { "classification" => "success", "exit_code" => 0 }
      end
    )
    sign_in!(login: "alice")

    post agent_skills_repair_path, params: { project: project }
    assert_response :unprocessable_entity
    assert_empty repairs, "a crafted POST without the form's consent marker must not provision agent files"

    post agent_skills_repair_path,
         params: { project: project, consent: "repair_managed_skills" }

    assert_redirected_to agents_path(project: project)
    assert_equal [ project ], repairs
    assert_equal "Managed agent skills are ready for #{project}.", flash[:notice]
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

  def register_skill_project(name)
    dir = File.join(ENV.fetch("HIVE_TEST_HOME_ROOT"), "skill-projects", name)
    FileUtils.mkdir_p(File.join(dir, ".hive-state"))
    File.write(File.join(dir, ".hive-state", "config.yml"), { "project_name" => name }.to_yaml)
    Hive::Config.register_project(name: name, path: dir, repository_identity: nil)
    name
  end

  def install_agent_skills_fake(inspect:, repair: ->(_entry) { raise "unexpected repair" })
    service = Object.new
    service.define_singleton_method(:inspect, &inspect)
    service.define_singleton_method(:repair, &repair)
    AgentsController.instance_variable_set(:@agent_skills, service)
  end

  def skill_row(health:, agent: "claude", capability: "ce-brainstorm")
    {
      "agent" => agent,
      "capability" => capability,
      "surfaces" => [ "brainstorm" ],
      "managed" => true,
      "health" => health,
      "severity" => health == "healthy" ? "info" : "error",
      "explanation" => "#{capability} is #{health}",
      "remediation" => "hive setup-agents --agent #{agent} --skill #{capability}"
    }
  end

  def seed_session(id, agent:, url:, output:, done:, error: nil)
    session = Hive::Web::AgentsAuth::Session.new(
      id: id, agent: agent, url: url, output: +output, done: done, error: error
    )
    AgentsController.agents_auth.instance_variable_get(:@sessions)[id] = session
  end
end
