require "test_helper"

class AgentLoginTest < ActiveSupport::TestCase
  class FakeAuth
    attr_reader :completed, :started, :written_token

    def initialize(session)
      @session = session
      @completed = []
      @started = []
    end

    def start(agent)
      @started << agent
      @session
    end

    def session(id)
      @session if @session.id == id
    end

    def output_for(id)
      session(id)&.output&.dup
    end

    def url_for(id)
      session(id)&.url
    end

    def poll_login?(agent)
      %w[codex grok gh].include?(agent.to_s)
    end

    def complete(id, code)
      @completed << [ id, code ]
    end

    def statuses
      { "codex" => { "logged_in" => true } }
    end

    def write_pi_token(token_json)
      @written_token = token_json
      "/tmp/pi-token"
    end
  end

  test "creates an immutable request snapshot and delegates completion" do
    session = build_session(agent: "codex", url: "https://auth.example/device")
    auth = FakeAuth.new(session)

    login = AgentLogin.create!("codex", auth:)
    session.output << " changed later"
    login.complete!("CODE-123")

    assert_equal [ "codex" ], auth.started
    assert_equal "device code", login.output
    assert login.operator_ward?
    assert login.polling?, "an operator-ward flow polls until its CLI exits"
    assert_equal [ [ "session-1", "CODE-123" ] ], auth.completed
  end

  test "paste-back flow stops polling once its URL is available" do
    waiting = AgentLogin.find!("session-1", auth: FakeAuth.new(build_session(agent: "claude")))
    ready = AgentLogin.find!(
      "session-1",
      auth: FakeAuth.new(build_session(agent: "claude", url: "https://claude.example/device"))
    )
    finished = AgentLogin.find!(
      "session-1",
      auth: FakeAuth.new(build_session(agent: "codex", done: true))
    )

    assert waiting.polling?
    refute ready.polling?
    refute finished.polling?
  end

  test "lookup binds the session id to the agent in the resource URL" do
    auth = FakeAuth.new(build_session(agent: "claude"))

    assert_raises(Hive::InvalidTaskPath) { AgentLogin.find!("missing", auth:) }
    assert_raises(Hive::InvalidTaskPath) do
      AgentLogin.find!("session-1", agent: "codex", auth:)
    end
  end

  test "class operations keep adapter details out of controllers" do
    auth = FakeAuth.new(build_session(agent: "codex"))

    assert_equal({ "codex" => { "logged_in" => true } }, AgentLogin.statuses(auth:))
    assert_equal "/tmp/pi-token", AgentLogin.write_pi_token!("{}", auth:)
    assert_equal "{}", auth.written_token
  end

  private

  def build_session(agent:, url: nil, done: false)
    Hive::Web::AgentsAuth::Session.new(
      id: "session-1", agent:, output: +"device code", url:, done:, error: nil
    )
  end
end
