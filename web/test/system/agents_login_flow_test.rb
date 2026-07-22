require "application_system_test_case"

class AgentsLoginFlowTest < ApplicationSystemTestCase
  teardown do
    AgentLogin.reset_auth!
  end

  test "agent login polling renders only its resource and stops on completion" do
    sign_in!
    auth = AgentLogin.auth
    session = Hive::Web::AgentsAuth::Session.new(
      id: "system-codex-login",
      agent: "codex",
      output: +"Enter code CODE-123",
      url: "https://auth.openai.com/codex/device",
      done: false
    )
    auth.instance_variable_get(:@sessions)[session.id] = session

    # A status refresh must never call this expensive full-page inventory.
    # Raising makes the browser test discriminate the dedicated resource from
    # the old AgentsController#login_status -> load_agents_page path.
    auth.define_singleton_method(:statuses) do
      raise "login polling rebuilt the full Agents inventory"
    end

    visit agent_login_status_path("codex", session.id)

    assert_selector "#agent-login [data-controller='poll']"
    assert_text "https://auth.openai.com/codex/device"
    assert_no_selector ".agent-cards", wait: 0
    assert_no_selector ".managed-skills", wait: 0

    auth.instance_variable_get(:@mutex).synchronize { session.done = true }

    assert_selector "#agent-login", text: "codex is now logged in", wait: 6
    assert_no_selector "#agent-login [data-controller='poll']", wait: 0
    assert_selector "#agent-login a[data-turbo-frame='_top']", text: "Back to agents"
  end
end
