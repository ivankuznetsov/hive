require "test_helper"

# The local-mode no-auth bypass: when `hive web` binds loopback and the
# operator has not opted out (web.local_loopback), the CLI exports
# HIVEBOX_LOCAL_LOOPBACK=1 so a same-host browser skips the GitHub login.
# The bypass MUST be gated on the request actually coming from loopback —
# the env var alone is not enough, or a box that ever set it would serve an
# unauthenticated dashboard to any remote that could reach the port.
class LocalLoopbackAuthTest < ActionDispatch::IntegrationTest
  setup do
    configure_owner!(owner: "alice")
    @prior_loopback = ENV["HIVEBOX_LOCAL_LOOPBACK"]
  end

  teardown do
    if @prior_loopback.nil?
      ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
    else
      ENV["HIVEBOX_LOCAL_LOOPBACK"] = @prior_loopback
    end
  end

  test "loopback request with the bypass enabled skips login" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"
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
  end

  test "bypass enabled but a non-loopback remote still requires login" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"
    # The env var is set, but the request originates off-host: the bypass must
    # NOT apply, or the dashboard would be exposed unauthenticated to a remote.
    get "/", headers: { "Host" => "localhost", "REMOTE_ADDR" => "203.0.113.5" }
    assert_redirected_to "/login", "a non-loopback request must require login even with the bypass enabled"
  end

  test "bypass disabled requires login even from loopback" do
    ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
    get "/"
    assert_redirected_to "/login", "without HIVEBOX_LOCAL_LOOPBACK every request must authenticate"
  end
  test "loopback peer with an attacker controlled Host is rejected" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"

    get "/", headers: { "Host" => "attacker.example" }

    assert_response :forbidden
  end

  test "loopback peer accepts the explicitly configured origin host" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"
    prior = ENV["HIVEBOX_ORIGIN"]
    ENV["HIVEBOX_ORIGIN"] = "https://hive.internal.example"

    get "/", headers: { "Host" => "hive.internal.example" }

    assert_response :success
  ensure
    prior.nil? ? ENV.delete("HIVEBOX_ORIGIN") : ENV["HIVEBOX_ORIGIN"] = prior
  end
end
