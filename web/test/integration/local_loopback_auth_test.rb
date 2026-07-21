require "test_helper"

# The local-mode no-auth bypass: when `hive web` binds loopback and the
# operator has not opted out (web.local_loopback), the CLI exports
# HIVE_WEB_LOCAL_LOOPBACK=1 so a same-host browser skips the GitHub login.
# The bypass MUST be gated on the request actually coming from loopback —
# the env var alone is not enough, or a box that ever set it would serve an
# unauthenticated dashboard to any remote that could reach the port.
class LocalLoopbackAuthTest < ActionDispatch::IntegrationTest
  ENV_KEYS = %w[
    HIVE_WEB_LOCAL_LOOPBACK
    HIVEBOX_LOCAL_LOOPBACK
    HIVE_WEB_ORIGIN
    HIVEBOX_ORIGIN
  ].freeze

  setup do
    configure_owner!(owner: "alice")
    @prior_environment = ENV_KEYS.to_h { |name| [ name, ENV[name] ] }
    ENV_KEYS.each { |name| ENV.delete(name) }
  end

  teardown do
    @prior_environment.each do |name, value|
      value.nil? ? ENV.delete(name) : ENV[name] = value
    end
  end

  test "loopback request with the bypass enabled skips login" do
    ENV["HIVE_WEB_LOCAL_LOOPBACK"] = "1"
    # Default integration-test remote_ip is 127.0.0.1 — a loopback request.
    get "/", headers: { "Host" => "localhost" }
    assert_response :success, "an enabled loopback bypass must serve the dashboard without a session"
    assert_select "nav[aria-label='Primary'] a", text: "Status"
    assert_select "nav[aria-label='Primary'] a", text: "Workflows"
    assert_select "nav[aria-label='Primary'] a", text: "Repos"
    assert_select "nav[aria-label='Primary'] a", text: "Agents"
    assert_select "nav[aria-label='Primary'] a", text: "Telegram"
    assert_select ".session-login", text: "Local"
    assert_select "a", text: "Connect GitHub"
    assert_select "form[action='/logout']", 0,
                  "a tokenless local session must not offer a meaningless logout action"
    assert_select "a.brand", text: "hive"
    assert_select "title", text: "hive — status"
    refute_includes response.body, "hivebox",
                    "local Hive Web must not present itself as the separate hivebox appliance"
  end

  test "loopback proxy remains local when it forwards the Tailscale client IP" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"

    get "/", headers: {
      "Host" => "localhost",
      "REMOTE_ADDR" => "127.0.0.1",
      "HTTP_X_FORWARDED_FOR" => "100.105.122.109"
    }

    assert_response :success,
                    "a localhost Tailscale Serve proxy must not turn Hive Web into a GitHub login gate"
    assert_select "nav[aria-label='Primary']", 1
  end

  test "legacy bypass alias still works but a non-loopback remote requires login" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"
    # The env var is set, but the request originates off-host: the bypass must
    # NOT apply, or the dashboard would be exposed unauthenticated to a remote.
    get "/", headers: { "Host" => "localhost", "REMOTE_ADDR" => "203.0.113.5" }
    assert_redirected_to "/login", "a non-loopback request must require login even with the bypass enabled"
  end

  test "loopback proxy remains local when forwarding the real client address" do
    ENV["HIVE_WEB_LOCAL_LOOPBACK"] = "1"

    get "/", headers: {
      "Host" => "localhost",
      "REMOTE_ADDR" => "127.0.0.1",
      "HTTP_X_FORWARDED_FOR" => "100.105.122.109"
    }

    assert_response :success
  end

  test "bypass disabled requires login even from loopback" do
    get "/"
    assert_redirected_to "/login", "without HIVE_WEB_LOCAL_LOOPBACK every request must authenticate"
  end
  test "loopback peer with an attacker controlled Host is rejected" do
    ENV["HIVE_WEB_LOCAL_LOOPBACK"] = "1"

    get "/", headers: { "Host" => "attacker.example" }

    assert_response :forbidden
  end

  test "attacker controlled Host cannot create an idea" do
    ENV["HIVE_WEB_LOCAL_LOOPBACK"] = "1"
    project = create_hive_project!("host-authorization-mutation")
    inbox = stage_dir(project, "1-inbox")
    before = inbox.children.map { |child| child.basename.to_s }

    post "/ideas", params: { project: project, text: "must not be created" },
                   headers: { "Host" => "attacker.example", "REMOTE_ADDR" => "127.0.0.1" }

    assert_response :forbidden
    assert_equal before, inbox.children.map { |child| child.basename.to_s },
                 "Host authorization must reject the mutation before the controller has a side effect"
  end

  test "loopback peer accepts the explicitly configured origin host" do
    ENV["HIVE_WEB_LOCAL_LOOPBACK"] = "1"
    ENV["HIVE_WEB_ORIGIN"] = "https://hive.internal.example"

    get "/", headers: { "Host" => "hive.internal.example" }

    assert_response :success
  end
end
