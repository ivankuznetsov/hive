require "test_helper"

# The box's primary authz gate: the REAL GithubAuth logic runs unstubbed —
# only Net::HTTP is replaced via the `http:` DI seam (the same seam the
# gem's unit suite uses): start → wait-page poll → grant/denial.
class SessionsFlowTest < ActionDispatch::IntegrationTest
  class FakeHttp
    def initialize(device:, token:, user:)
      @device = device
      @token = token
      @user = user
    end

    def start(host, _port, **_opts)
      @host = host
      yield self
    end

    def request(req)
      return @user if @host == "api.github.com"

      req.path.include?("/login/device/code") ? @device : @token
    end
  end

  DEVICE_BODY = JSON.generate(
    "device_code" => "dev-1", "user_code" => "ABCD-1234",
    "verification_uri" => "https://github.com/login/device",
    "expires_in" => 900,
    # interval 0 → the first wait-page render polls immediately.
    "interval" => 0
  )

  setup do
    @prior_local_loopback = ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
    configure_owner!(owner: "alice")
  end

  teardown do
    SessionsController.http_client = Net::HTTP
    if @prior_local_loopback.nil?
      ENV.delete("HIVEBOX_LOCAL_LOOPBACK")
    else
      ENV["HIVEBOX_LOCAL_LOOPBACK"] = @prior_local_loopback
    end
  end

  def http_ok(body)
    res = Net::HTTPOK.new("1.1", "200", "OK")
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end

  def install_auth(login: "alice", token_body: nil)
    token_body ||= JSON.generate("access_token" => "gho_test")
    SessionsController.http_client = FakeHttp.new(
      device: http_ok(DEVICE_BODY),
      token: http_ok(token_body),
      user: http_ok(JSON.generate("login" => login))
    )
  end

  def begin_device_flow
    post "/auth/github"
    assert_redirected_to "/auth/github/wait", "starting the device flow must land on the waiting page"
  end

  test "unauthenticated requests redirect to login" do
    get "/"
    assert_redirected_to "/login"
  end

  test "wait without a started flow returns to login" do
    install_auth
    get "/auth/github/wait"
    assert_redirected_to "/login"
  end

  test "pending grant keeps showing the user code without a session" do
    install_auth(token_body: JSON.generate("error" => "authorization_pending"))
    begin_device_flow

    get "/auth/github/wait"

    assert_response :success
    assert_match "ABCD-1234", response.body, "the waiting page must show the user code while pending"
    get "/"
    assert_redirected_to "/login", "a pending grant must not produce a session"
  end

  test "denied grant surfaces a sign-in failed page" do
    install_auth(token_body: JSON.generate("error" => "access_denied"))
    begin_device_flow

    get "/auth/github/wait"

    assert_response :forbidden
    assert_match "denied", response.body
  end

  test "expired device code surfaces and clears the flow" do
    install_auth(token_body: JSON.generate("error" => "expired_token"))
    begin_device_flow

    get "/auth/github/wait"

    assert_response :forbidden
    assert_match(/expired/i, response.body)
  end

  test "an owner change evicts existing sessions" do
    configure_owner!(owner: "alice")
    install_auth(login: "alice")
    begin_device_flow
    get "/auth/github/wait"
    assert_redirected_to "/"
    get "/"
    assert_response :success

    # The box changes hands (config edit / re-claim): alice's session must
    # die with her ownership — it holds a repo-scoped token.
    configure_owner!(owner: "bob")
    get "/"
    assert_redirected_to "/login"
    assert_nil session[:github_token], "the evicted session must not keep the grant"
  end

  test "a fresh box is claimed by its first successful login" do
    configure_owner!(owner: "")
    install_auth(login: "firstcomer")
    begin_device_flow

    get "/auth/github/wait"

    assert_redirected_to "/", "the first login claims an ownerless box"
    config = YAML.safe_load_file(File.join(ENV["HIVE_HOME"], "config.yml"))
    assert_equal "firstcomer", config.dig("web", "github", "owner"),
                 "the claim must be persisted — it IS the box's auth gate from now on"

    get "/"
    assert_response :success, "the claimer is the owner; their session must work"
  end

  test "a claimed box refuses every later non-owner login" do
    configure_owner!(owner: "")
    install_auth(login: "firstcomer")
    begin_device_flow
    get "/auth/github/wait"
    assert_redirected_to "/"

    delete "/logout" rescue post "/logout"
    install_auth(login: "secondcomer")
    begin_device_flow
    get "/auth/github/wait"

    assert_response :forbidden
    assert_match "not the configured owner", response.body,
                 "claiming is once — a claimed box is gated exactly like a configured one"
  end

  test "the login page explains claiming on a fresh box" do
    configure_owner!(owner: "")
    get "/login"
    assert_response :success
    assert_match "first GitHub sign-in becomes its owner", response.body
    assert_select "form[action='/auth/github']", 1,
                  "the claim path must be one button, not a config-editing instruction"
  end

  test "local Hive Web presents GitHub as an optional connection, not box ownership" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"
    configure_owner!(owner: "")

    get "/login"

    assert_response :success
    assert_select "h1", text: "Connect GitHub"
    assert_match(/optional/i, response.body)
    refute_match(/Fresh box|becomes its owner/, response.body)
    refute_includes response.body, "hivebox"
  end

  test "local GitHub connection retains the token without claiming box ownership" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"
    configure_owner!(owner: "")
    install_auth(login: "local-operator")
    begin_device_flow

    get "/auth/github/wait"

    assert_redirected_to "/"
    assert_equal "local-operator", session[:github_login]
    assert_equal "gho_test", session[:github_token]
    config = YAML.safe_load_file(File.join(ENV["HIVE_HOME"], "config.yml"))
    assert_nil config.dig("web", "github", "owner"),
               "connecting GitHub in local mode must not turn Hive Web into a claimed hivebox"
  end

  test "non-owner login is denied (U2)" do
    install_auth(login: "mallory")
    begin_device_flow

    get "/auth/github/wait"

    assert_response :forbidden
    assert_match "not the configured owner", response.body

    get "/"
    assert_redirected_to "/login", "a denied login must not leave a usable session"
  end

  test "owner is admitted and the grant token is kept for the repos page" do
    install_auth(login: "alice")
    begin_device_flow

    get "/auth/github/wait"

    assert_redirected_to "/"
    get "/"
    assert_response :success, "the owner's session must survive into the status grid"
    assert_equal "gho_test", session[:github_token], "the repo-scoped grant must be retained"
  end

  test "logout clears the session" do
    sign_in!
    post "/logout"
    assert_redirected_to "/login"
    get "/"
    assert_redirected_to "/login", "the session must be gone after logout"
  end

  test "disconnecting GitHub in local mode returns to Hive instead of the login gate" do
    ENV["HIVEBOX_LOCAL_LOOPBACK"] = "1"
    sign_in!(token: "gho_test")

    post "/logout"

    assert_redirected_to "/"
    follow_redirect!
    assert_response :success
    assert_nil session[:github_token]
    assert_select ".session-login", text: "Local"
  end
end
