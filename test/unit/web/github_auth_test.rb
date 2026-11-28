require "test_helper"
require "logger"
require "net/http"
require "openssl"
require "stringio"
require "timeout"
require "hive/web/github_auth"

class GithubAuthTest < Minitest::Test
  SENTINEL_HOST = "internal-proxy.secret.example".freeze
  SENTINEL_URL = "https://#{SENTINEL_HOST}/oauth/token?state=secret-query-99".freeze
  SENTINEL_TOKEN = "gho_secretSentinelToken123456".freeze
  SENTINEL_MESSAGE = "handshake failed for #{SENTINEL_URL} bearer=#{SENTINEL_TOKEN}".freeze

  # Drives the `http:` DI seam without a network round-trip. Routes on the
  # request path (device-code vs token vs user endpoint) and RECORDS every
  # outgoing request so tests can assert the wire contract (path, form
  # fields, headers) — not just response handling.
  class FakeHttp
    Recorded = Struct.new(:host, :path, :body, :headers)

    attr_reader :requests

    def initialize(responses)
      @responses = responses
      @requests = []
    end

    def start(host, _port, **_opts)
      @host = host
      yield self
    end

    def request(req)
      @requests << Recorded.new(@host, req.path, req.body.to_s, req.to_hash)
      key =
        if @host == "api.github.com" then :user
        elsif req.path.include?("/login/device/code") then :device
        else :token
        end
      outcome = @responses.fetch(key)
      raise outcome if outcome.is_a?(Exception)

      outcome
    end
  end

  class RecordingLogger
    attr_reader :warnings

    def initialize
      @warnings = []
    end

    def warn(message = nil)
      @warnings << (block_given? ? yield : message)
    end
  end

  # An http seam that raises an injected error on first contact.
  class RaisingHttp
    def initialize(error)
      @error = error
    end

    def start(*) = raise @error
  end

  def self.http_ok(body)
    res = Net::HTTPOK.new("1.1", "200", "OK")
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end

  def self.http_status(klass, code, reason, body = "")
    res = klass.new("1.1", code, reason)
    res.instance_variable_set(:@read, true)
    res.define_singleton_method(:body) { body }
    res
  end

  DEVICE_OK = JSON.generate(
    "device_code" => "dev-1", "user_code" => "ABCD-1234",
    "verification_uri" => "https://github.com/login/device",
    "expires_in" => 899, "interval" => 5
  )

  def build_auth(device: DEVICE_OK, token: nil, user: nil, logger: RecordingLogger.new)
    http = FakeHttp.new(
      device: device.is_a?(String) ? self.class.http_ok(device) : device,
      token: token.is_a?(String) || token.nil? ? self.class.http_ok(token.to_s) : token,
      user: user.is_a?(String) || user.nil? ? self.class.http_ok(user.to_s) : user
    )
    auth = Hive::Web::GithubAuth.new(
      config: { "github" => { "client_id" => "cid", "owner" => "octo" } },
      http: http,
      logger: logger
    )
    [ auth, http, logger ]
  end

  def null_logger
    Logger.new(IO::NULL)
  end

  def test_start_device_flow_returns_codes_and_sends_client_id_and_scope
    auth, http = build_auth

    device = auth.start_device_flow

    assert_equal "ABCD-1234", device["user_code"], "user_code must come from the GitHub payload"
    assert_equal "dev-1", device["device_code"]
    req = http.requests.first
    assert_equal "/login/device/code", req.path, "device authorization must hit the device-code endpoint"
    assert_match(/client_id=cid/, req.body)
    assert_match(/scope=read%3Auser/, req.body)
  end

  def test_start_device_flow_raises_on_error_payload
    auth, = build_auth(device: JSON.generate("error" => "unauthorized_client", "error_description" => "device flow disabled"))

    error = assert_raises(Hive::Error) { auth.start_device_flow }
    assert_match(/device flow disabled/, error.message)
  end

  def test_start_device_flow_raises_on_missing_fields
    auth, = build_auth(device: JSON.generate("user_code" => "ABCD-1234"))

    error = assert_raises(Hive::Error) { auth.start_device_flow }
    assert_match(/missing device_code/, error.message)
  end

  def test_poll_grants_login_and_sends_device_grant_contract
    auth, http = build_auth(
      token: JSON.generate("access_token" => "tok"),
      user: JSON.generate("login" => "octo", "id" => 42)
    )

    result = auth.poll_device_flow("dev-1")

    assert_equal({ state: :ok, login: "octo", id: 42, token: "tok" }, result,
                 "the granted token must be returned for callers that need API access (repo listing)")
    token_req = http.requests.find { |r| r.path.include?("/login/oauth/access_token") }
    assert token_req, "the poll must hit the token endpoint"
    assert_match(/device_code=dev-1/, token_req.body)
    assert_match(/grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code/, token_req.body)
    user_req = http.requests.find { |r| r.host == "api.github.com" }
    assert_equal "Bearer tok", user_req.headers["authorization"].first, "the user lookup must carry the granted token"
  end

  def test_poll_maps_pending_slow_down_denied_and_expired
    { "authorization_pending" => { state: :pending },
      "access_denied" => { state: :denied },
      "expired_token" => { state: :expired } }.each do |error, expected|
      auth, = build_auth(token: JSON.generate("error" => error))
      assert_equal expected, auth.poll_device_flow("dev-1"), "GitHub error #{error} must map to #{expected[:state]}"
    end

    # RFC 8628 §3.5: slow_down is additive, so the payload's own `interval`
    # (when GitHub sends one) must be ignored in favor of the fixed penalty.
    auth, = build_auth(token: JSON.generate("error" => "slow_down", "interval" => 11))
    assert_equal({ state: :slow_down, increase_by: Hive::Web::GithubAuth::SLOW_DOWN_PENALTY },
                 auth.poll_device_flow("dev-1"),
                 "slow_down must report the additive penalty, not an absolute interval")

    auth, = build_auth(token: JSON.generate("error" => "slow_down"))
    assert_equal({ state: :slow_down, increase_by: 5 }, auth.poll_device_flow("dev-1"),
                 "slow_down without an interval member still reports the +5 penalty")
  end

  def test_poll_raises_on_unknown_error_payload
    auth, = build_auth(token: JSON.generate("error" => "incorrect_device_code"))

    error = assert_raises(Hive::Error) { auth.poll_device_flow("dev-1") }
    assert_match(/incorrect_device_code/, error.message)
  end

  def test_poll_raises_on_unparseable_token_response
    # A proxy/error page returns 200 with non-JSON; JSON.parse raises and the
    # rescue must surface a clean Hive::Error, not a raw JSON::ParserError.
    auth, = build_auth(token: "<html>not json</html>")

    error = assert_raises(Hive::Error) { auth.poll_device_flow("dev-1") }
    assert_match(/unparseable response/, error.message)
  end

  def test_poll_raises_on_unparseable_user_response
    auth, = build_auth(
      token: JSON.generate("access_token" => "tok"),
      user: "<html>not json</html>"
    )

    error = assert_raises(Hive::Error) { auth.poll_device_flow("dev-1") }
    assert_match(/user lookup returned an unparseable response/, error.message)
  end

  def test_network_errors_constant_uses_transport_superclasses
    network_errors = Hive::Web::GithubAuth::NETWORK_ERRORS

    assert_includes network_errors, SystemCallError
    assert_includes network_errors, IOError
    assert_includes network_errors, OpenSSL::SSL::SSLError
    assert_includes network_errors, SocketError
    assert_includes network_errors, Net::OpenTimeout
    assert_includes network_errors, Net::ReadTimeout
    assert_includes network_errors, Net::WriteTimeout
    assert_includes network_errors, Timeout::Error
    refute network_errors.any? { |klass| klass < SystemCallError },
           "NETWORK_ERRORS must rely on SystemCallError rather than enumerated Errno subclasses"
    refute_includes network_errors, EOFError,
                    "NETWORK_ERRORS must cover EOFError through IOError rather than a separate entry"
  end

  def test_transport_matrix_maps_to_shared_guidance_and_redacted_warning
    matrix = [
      [ OpenSSL::SSL::SSLError.new(SENTINEL_MESSAGE), "tls_failure" ],
      [ SocketError.new(SENTINEL_MESSAGE), "dns_failure" ],
      [ Net::OpenTimeout.new(SENTINEL_MESSAGE), "open_timeout" ],
      [ Net::ReadTimeout.new(SENTINEL_MESSAGE), "read_timeout" ],
      [ Net::WriteTimeout.new(SENTINEL_MESSAGE), "write_timeout" ],
      [ Timeout::Error.new(SENTINEL_MESSAGE), "connection_timeout" ],
      [ Errno::ECONNREFUSED.new(SENTINEL_MESSAGE), "connection_refused" ],
      [ Errno::ECONNRESET.new(SENTINEL_MESSAGE), "connection_reset" ],
      [ Errno::ETIMEDOUT.new(SENTINEL_MESSAGE), "connection_timeout" ],
      [ Errno::ENETUNREACH.new(SENTINEL_MESSAGE), "network_unreachable" ],
      [ Errno::EHOSTUNREACH.new(SENTINEL_MESSAGE), "host_unreachable" ],
      [ EOFError.new(SENTINEL_MESSAGE), "premature_eof" ],
      [ Errno::EPIPE.new(SENTINEL_MESSAGE), "system_call_failure" ],
      [ IOError.new(SENTINEL_MESSAGE), "io_failure" ]
    ]

    matrix.each do |injected, expected_reason|
      logger = RecordingLogger.new
      auth = Hive::Web::GithubAuth.new(
        config: { "github" => { "client_id" => "cid", "owner" => "octo" } },
        http: RaisingHttp.new(injected),
        logger: logger
      )

      error = assert_raises(Hive::Error, "expected #{injected.class} to normalize to Hive::Error") do
        auth.start_device_flow
      end

      assert_equal Hive::Web::GithubAuth::TRANSPORT_ERROR_MESSAGE, error.message
      assert_nil error.cause, "translated Hive::Error must sever the raw transport cause for #{injected.class}"
      [ SENTINEL_HOST, SENTINEL_URL, SENTINEL_TOKEN, injected.class.name ].each do |forbidden|
        refute_includes error.message, forbidden
      end

      assert_equal 1, logger.warnings.length, "expected one warning for #{injected.class}"
      raw_warning = logger.warnings.first
      [ SENTINEL_HOST, SENTINEL_URL, SENTINEL_TOKEN, "secret-query-99" ].each do |forbidden|
        refute_includes raw_warning, forbidden
      end
      parsed = JSON.parse(raw_warning)
      assert_equal(
        {
          "event" => Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT,
          "operation" => "github_device_authorization",
          "reason" => expected_reason,
          "error_class" => injected.class.name
        },
        parsed
      )
    end
  end

  def test_device_flow_operations_emit_distinct_literal_operation_labels
    device_logger = RecordingLogger.new
    device_auth, = build_auth(
      device: OpenSSL::SSL::SSLError.new(SENTINEL_MESSAGE),
      logger: device_logger
    )
    assert_raises(Hive::Error) { device_auth.start_device_flow }

    poll_logger = RecordingLogger.new
    poll_auth, = build_auth(
      token: Errno::ENETUNREACH.new(SENTINEL_MESSAGE),
      logger: poll_logger
    )
    assert_raises(Hive::Error) { poll_auth.poll_device_flow("secret-device-code-99") }

    user_logger = RecordingLogger.new
    user_auth, = build_auth(
      token: JSON.generate("access_token" => SENTINEL_TOKEN),
      user: Errno::ECONNRESET.new(SENTINEL_MESSAGE),
      logger: user_logger
    )
    assert_raises(Hive::Error) { user_auth.poll_device_flow("secret-device-code-99") }

    operations = [
      JSON.parse(device_logger.warnings.first).fetch("operation"),
      JSON.parse(poll_logger.warnings.first).fetch("operation"),
      JSON.parse(user_logger.warnings.first).fetch("operation")
    ]
    assert_equal %w[github_device_authorization github_device_grant_poll github_user_lookup], operations
    operations.each do |operation|
      refute_includes operation, "http"
      refute_includes operation, "secret"
      refute_includes operation, SENTINEL_TOKEN
    end
  end

  def test_warn_transport_supports_api_operation_and_explicit_total_deadline_provenance
    logger = RecordingLogger.new
    timeout_error = Timeout::Error.new(SENTINEL_MESSAGE)

    Hive::Web::GithubAuth.warn_transport(
      logger: logger,
      operation: "github_api_pull_request",
      error: timeout_error,
      total_deadline: false
    )
    Hive::Web::GithubAuth.warn_transport(
      logger: logger,
      operation: "github_api_pull_request",
      error: timeout_error,
      total_deadline: true
    )

    assert_equal 2, logger.warnings.length
    assert_equal(
      {
        "event" => Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT,
        "operation" => "github_api_pull_request",
        "reason" => "connection_timeout",
        "error_class" => "Timeout::Error"
      },
      JSON.parse(logger.warnings[0])
    )
    assert_equal(
      {
        "event" => Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT,
        "operation" => "github_api_pull_request",
        "reason" => "total_deadline",
        "error_class" => "Timeout::Error"
      },
      JSON.parse(logger.warnings[1])
    )
    logger.warnings.each { |line| refute_includes line, SENTINEL_TOKEN }
  end

  def test_non_transport_http_json_and_payload_errors_emit_no_transport_warning
    bad_status_logger = RecordingLogger.new
    bad_status_auth, = build_auth(
      device: self.class.http_status(Net::HTTPInternalServerError, "500", "Internal Server Error", "{}"),
      logger: bad_status_logger
    )
    error = assert_raises(Hive::Error) { bad_status_auth.start_device_flow }
    assert_equal "GitHub device authorization failed (HTTP 500)", error.message
    assert_empty bad_status_logger.warnings

    bad_user_status_logger = RecordingLogger.new
    bad_user_status_auth, = build_auth(
      token: JSON.generate("access_token" => "tok"),
      user: self.class.http_status(Net::HTTPUnauthorized, "401", "Unauthorized", "{}"),
      logger: bad_user_status_logger
    )
    error = assert_raises(Hive::Error) { bad_user_status_auth.poll_device_flow("dev-1") }
    assert_equal "GitHub user lookup failed (HTTP 401)", error.message
    assert_empty bad_user_status_logger.warnings

    malformed_json_logger = RecordingLogger.new
    malformed_json_auth, = build_auth(device: "<html>not json</html>", logger: malformed_json_logger)
    error = assert_raises(Hive::Error) { malformed_json_auth.start_device_flow }
    assert_equal "GitHub device authorization returned an unparseable response", error.message
    assert_empty malformed_json_logger.warnings

    missing_fields_logger = RecordingLogger.new
    missing_fields_auth, = build_auth(
      device: JSON.generate("user_code" => "ABCD-1234"),
      logger: missing_fields_logger
    )
    error = assert_raises(Hive::Error) { missing_fields_auth.start_device_flow }
    assert_match(/missing device_code/, error.message)
    assert_empty missing_fields_logger.warnings

    missing_token_logger = RecordingLogger.new
    missing_token_auth, = build_auth(token: JSON.generate({}), logger: missing_token_logger)
    error = assert_raises(Hive::Error) { missing_token_auth.poll_device_flow("dev-1") }
    assert_equal "GitHub device grant returned no access_token", error.message
    assert_empty missing_token_logger.warnings

    missing_login_logger = RecordingLogger.new
    missing_login_auth, = build_auth(
      token: JSON.generate("access_token" => "tok"),
      user: JSON.generate("id" => 42),
      logger: missing_login_logger
    )
    error = assert_raises(Hive::Error) { missing_login_auth.poll_device_flow("dev-1") }
    assert_equal "GitHub user lookup returned no login", error.message
    assert_empty missing_login_logger.warnings

    invalid_id_logger = RecordingLogger.new
    invalid_id_auth, = build_auth(
      token: JSON.generate("access_token" => "tok"),
      user: JSON.generate("login" => "octo", "id" => "42"),
      logger: invalid_id_logger
    )
    error = assert_raises(Hive::Error) { invalid_id_auth.poll_device_flow("dev-1") }
    assert_equal "GitHub user lookup returned no positive numeric id", error.message
    assert_empty invalid_id_logger.warnings
  end

  def test_programming_and_malformed_response_errors_are_not_normalized
    malformed_logger = RecordingLogger.new
    malformed_auth, = build_auth(device: Object.new, logger: malformed_logger)
    error = assert_raises(NoMethodError) { malformed_auth.start_device_flow }
    refute_equal Hive::Web::GithubAuth::TRANSPORT_ERROR_MESSAGE, error.message
    assert_empty malformed_logger.warnings

    bug_logger = RecordingLogger.new
    bug_auth = Hive::Web::GithubAuth.new(
      config: { "github" => { "client_id" => "cid", "owner" => "octo" } },
      http: RaisingHttp.new(NoMethodError.new("undefined method `foo'")),
      logger: bug_logger
    )
    error = assert_raises(NoMethodError) { bug_auth.start_device_flow }
    assert_match(/undefined method/, error.message)
    assert_empty bug_logger.warnings
  end

  def test_initialize_requires_explicit_logger
    assert_raises(ArgumentError) do
      Hive::Web::GithubAuth.new(config: { "github" => { "client_id" => "cid" } })
    end
  end

  def test_configured_requires_client_id_only_and_ownerless_is_claimable
    auth = Hive::Web::GithubAuth.new(
      config: { "github" => { "client_id" => "cid", "owner" => "octo" } },
      logger: null_logger
    )
    assert auth.configured?, "device flow needs no client secret — client_id suffices"
    refute auth.claimable?, "a pinned owner keeps the gate closed"

    no_owner = Hive::Web::GithubAuth.new(
      config: { "github" => { "client_id" => "cid" } },
      logger: null_logger
    )
    assert no_owner.configured?, "an ownerless box can still START sign-in (the first login claims it)"
    assert no_owner.claimable?

    no_client = Hive::Web::GithubAuth.new(config: { "github" => {} }, logger: null_logger)
    refute no_client.configured?, "without a client_id no flow can start"
  end

  def test_owner_match_is_case_insensitive
    auth = Hive::Web::GithubAuth.new(
      config: { "github" => { "owner" => "Alice", "client_id" => "id" } },
      logger: null_logger
    )

    assert auth.owner?("alice")
    refute auth.owner?("bob")
  end

  def test_maintenance_owner_requires_matching_login_and_numeric_id
    auth = Hive::Web::GithubAuth.new(
      config: { "github" => { "owner" => "Alice", "owner_id" => 42, "client_id" => "id" } },
      logger: null_logger
    )

    assert auth.maintenance_owner?("alice", 42)
    refute auth.maintenance_owner?("alice", 43)
    refute auth.maintenance_owner?("bob", 42)
    refute Hive::Web::GithubAuth.new(
      config: { "github" => { "owner" => "Alice", "client_id" => "id" } },
      logger: null_logger
    ).maintenance_owner?("alice", 42)
  end
end
