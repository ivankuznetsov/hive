require "test_helper"

# Regression guard for the Agents login-status 500. The CLI relay buffers
# raw ASCII-8BIT PTY bytes; rendering them into the UTF-8 `<pre>` view raised
# Encoding::CompatibilityError (a 500 on /agents/<agent>/login/<id>). The lib
# suite never caught it — its only direct `output_for` test used clean ASCII
# and the login fakes echoed clean text, and nothing drove the Rails resource +
# view. This exercises the exact layer that broke: a binary-output session
# rendered through the real view.
class AgentsTest < ActionDispatch::IntegrationTest
  teardown do
    # AgentLogin owns the class-memoized process relay. Drop it so a seeded
    # PTY session cannot leak into another request example.
    AgentLogin.reset_auth!
    AgentsController.instance_variable_set(:@agent_skills, nil)
  end

  test "login_status renders binary CLI output as 200, not a 500" do
    sign_in!(login: "alice")

    auth = AgentLogin.auth
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
    auth.define_singleton_method(:statuses) do
      raise "a login-status refresh must not rebuild the full Agents inventory"
    end

    get agent_login_status_path("claude", "sess-bin")

    assert_response :success
    assert_match "https://example.com/auth", response.body,
                 "the authorize URL must render so the operator can finish login"
    assert_select ".agent-cards", count: 0
    assert_select ".managed-skills", count: 0
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

  test "login frame refresh does not return a self-referential source" do
    sign_in!(login: "alice")
    seed_session("sess-frame", agent: "codex", url: "https://auth.openai.com/codex/device",
                 output: "Enter this code: FRAME-CODE", done: false)

    get agent_login_status_path("codex", "sess-frame"),
        headers: { "Turbo-Frame" => "agent-login" }

    assert_response :success
    assert_select "turbo-frame#agent-login[src]", { count: 0 },
                  "Turbo rejects a matching frame whose src points back to the request URL"
    assert_select "turbo-frame#agent-login [data-controller='poll']", count: 1
    assert_match "https://auth.openai.com/codex/device", response.body
  end

  test "login URLs keep their verbs while routing through named resources" do
    create_route = Rails.application.routes.recognize_path(agent_login_path("codex"), method: :post)
    show_route = Rails.application.routes.recognize_path(
      agent_login_status_path("codex", "session-1"), method: :get
    )
    completion_route = Rails.application.routes.recognize_path(
      agent_login_complete_path("codex", "session-1"), method: :post
    )

    assert_equal({ controller: "agents/logins", action: "create" }, create_route.slice(:controller, :action))
    assert_equal({ controller: "agents/logins", action: "show" }, show_route.slice(:controller, :action))
    assert_equal({ controller: "agents/login_completions", action: "create" },
                 completion_route.slice(:controller, :action))
  end

  test "login status refuses a session under a different agent URL" do
    sign_in!(login: "alice")
    seed_session("sess-claude-agent", agent: "claude", url: "https://claude.ai/device",
                 output: "paste the code", done: false)

    get agent_login_status_path("codex", "sess-claude-agent")

    assert_response :not_found
    assert_match "unknown login session", response.body
  end

  test "agents page offers the supported Grok device login" do
    sign_in!(login: "alice")

    # This scenario exercises the first-login CTA, independent of whether the
    # developer running the suite has real Grok credentials in their home.
    original_logged_in = Hive::AgentProfiles.method(:logged_in?)
    begin
      Hive::AgentProfiles.define_singleton_method(:logged_in?) { |_agent| false }
      get agents_path
    ensure
      Hive::AgentProfiles.define_singleton_method(:logged_in?, original_logged_in)
    end

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
    assert_select "a[data-turbo-frame='_top'][href='#{agents_path}']", text: "Back to agents"
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
      health: lambda do |entry|
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
      health: ->(_entry) { rows },
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

  test "failed managed skill repair shows and logs the command cause" do
    project = register_skill_project("agent-repair-failure-app")
    install_agent_skills_fake(
      health: ->(_entry) { [ skill_row(health: "missing") ] },
      repair: lambda do |_entry|
        {
          "classification" => "residual_failure", "exit_code" => 1,
          "operation_results" => [ {
            "operation_id" => "install-claude-skills",
            "status" => "failed",
            "message" => "registry request timed out"
          } ]
        }
      end
    )
    sign_in!(login: "alice")

    post agent_skills_repair_path,
         params: { project: project, consent: "repair_managed_skills" }

    assert_redirected_to agents_path(project: project)
    assert_match(/residual failure.*install-claude-skills.*registry request timed out/, flash[:alert])
  end

  test "paste-back agent (claude) keeps the code form and stops polling at the URL" do
    sign_in!(login: "alice")
    seed_session("sess-claude", agent: "claude", url: "https://claude.ai/device",
                 output: "paste the code", done: false)

    get agent_login_status_path("claude", "sess-claude")

    assert_response :success
    assert_match "Complete login", response.body, "paste-back agents keep the code form"
    assert_select "form[data-turbo-frame='_top'][action='#{agent_login_complete_path("claude", "sess-claude")}']"
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

  def install_agent_skills_fake(health:, repair: ->(_entry) { raise "unexpected repair" })
    service = Object.new
    service.define_singleton_method(:health, &health)
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
    AgentLogin.auth.instance_variable_get(:@sessions)[id] = session
  end
end
