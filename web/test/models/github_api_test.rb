require "test_helper"
require "openssl"
require "stringio"
require "timeout"

class GithubApiTest < ActiveSupport::TestCase
  SENTINEL_HOST = "api-proxy.secret.example".freeze
  SENTINEL_URL = "https://#{SENTINEL_HOST}/graphql?token=gho_secretApiToken99".freeze
  SENTINEL_TOKEN = "gho_secretApiToken99".freeze
  SENTINEL_MESSAGE = "socket error talking to #{SENTINEL_URL} auth=#{SENTINEL_TOKEN}".freeze

  class Transport
    attr_reader :calls

    def initialize(response = nil, &block)
      @response = response
      @block = block
      @calls = []
    end

    def call(**kwargs)
      @calls << kwargs
      @block ? @block.call(**kwargs) : @response
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

  test "publication uses one fixed bounded query and normalizes checks" do
    response = GithubApi::Response.new(
      code: "200", headers: {}, body: JSON.generate(graphql_document)
    )
    transport = Transport.new(response)
    api = GithubApi.new("private-token", transport: transport)

    result = api.pull_request(
      repository: "github.com/acme/demo", number: 42,
      expected_head: "a" * 40
    )

    assert_equal 1, transport.calls.length
    call = transport.calls.first
    assert_equal "https://api.github.com/graphql", call.fetch(:uri).to_s
    assert_equal 256 * 1024, call.fetch(:max_bytes)
    assert_equal "Bearer private-token", call.fetch(:request)["Authorization"]
    request = JSON.parse(call.fetch(:request).body)
    assert_equal({ "owner" => "acme", "name" => "demo", "number" => 42,
                   "checks" => 100 }, request.fetch("variables"))
    assert_equal "github.com/acme/demo", result.fetch("repository")
    assert result.fetch("head_matches")
    assert_equal %w[test legacy], result.fetch("checks").map { |row| row.fetch("name") }
    assert result.fetch("checks_truncated")
  end

  test "a changed remote head is returned as conflict evidence, not rewritten" do
    document = graphql_document
    document.dig("data", "repository", "pullRequest")["headRefOid"] = "b" * 40
    transport = Transport.new(
      GithubApi::Response.new(code: "200", headers: {}, body: JSON.generate(document))
    )

    result = GithubApi.new("token", transport: transport).pull_request(
      repository: "github.com/acme/demo", number: 42,
      expected_head: "a" * 40
    )

    assert_equal "b" * 40, result.fetch("head_oid")
    assert_equal "a" * 40, result.fetch("expected_head")
    refute result.fetch("head_matches")
  end

  test "identity validation rejects foreign hosts and bad heads before transport" do
    transport = Transport.new
    api = GithubApi.new("token", transport: transport)

    errors = [
      assert_raises(GithubApi::ReadError) do
        api.pull_request(repository: "enterprise.example/acme/demo", number: 42,
                         expected_head: "a" * 40)
      end,
      assert_raises(GithubApi::ReadError) do
        api.pull_request(repository: "github.com/acme/demo", number: 42,
                         expected_head: "short")
      end
    ]

    assert errors.all? { |error| error.reason == "identity_invalid" }
    assert_empty transport.calls
  end

  test "rate limits authentication invalid JSON and response caps are typed" do
    cases = [
      [ GithubApi::Response.new(code: "429", headers: { "retry-after" => "60" }, body: "{}"),
        "rate_limited" ],
      [ GithubApi::Response.new(code: "401", headers: {}, body: "{}"), "unauthenticated" ],
      [ GithubApi::Response.new(code: "200", headers: {}, body: "not json"), "response_invalid" ],
      [ GithubApi::Response.new(code: "200", headers: {}, body: "x" * 257), "response_oversized" ]
    ]
    cases.each do |response, reason|
      error = assert_raises(GithubApi::ReadError) do
        GithubApi.new("token", transport: Transport.new(response)).pull_request(
          repository: "github.com/acme/demo", number: 42,
          expected_head: "a" * 40, max_bytes: 256
        )
      end
      assert_equal reason, error.reason
      assert_equal "60", error.retry_after if reason == "rate_limited"
    end
  end

  test "GraphQL errors and missing pull requests are not fabricated" do
    [
      [ { "errors" => [ { "message" => "no" } ] }, "github_response_error" ],
      [ { "data" => { "repository" => { "pullRequest" => nil } } }, "pull_request_missing" ]
    ].each do |document, reason|
      response = GithubApi::Response.new(code: "200", headers: {}, body: JSON.generate(document))
      error = assert_raises(GithubApi::ReadError) do
        GithubApi.new("token", transport: Transport.new(response)).pull_request(
          repository: "github.com/acme/demo", number: 42,
          expected_head: "a" * 40
        )
      end
      assert_equal reason, error.reason
    end
  end

  test "publication enforces one total request deadline" do
    logger = RecordingLogger.new
    transport = Transport.new do |**|
      sleep 0.05
      GithubApi::Response.new(code: "200", headers: {}, body: JSON.generate(graphql_document))
    end

    error = assert_raises(GithubApi::ReadError) do
      GithubApi.new("token", transport: transport, total_timeout: 0.01, logger: logger).pull_request(
        repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40
      )
    end

    assert_equal "deadline_exceeded", error.reason
    assert_equal "GitHub API request exceeded its total deadline", error.message
    assert_nil error.cause
    assert_equal 1, logger.warnings.length
    assert_equal(
      {
        "event" => Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT,
        "operation" => "github_api_pull_request",
        "reason" => "total_deadline",
        "error_class" => "GithubApi::TotalDeadlineExceeded"
      },
      JSON.parse(logger.warnings.first)
    )
    assert_raises(NameError) { GithubApi::TotalDeadlineExceeded }
  end

  test "shares the GitHub transport exception family and guidance" do
    assert_same Hive::Web::GithubAuth::NETWORK_ERRORS, GithubApi::NETWORK_ERRORS
  end

  test "transport matrix normalizes failures to network_failed with shared guidance and redacted warning" do
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
      transport = Transport.new { |**| raise injected }

      error = assert_raises(GithubApi::ReadError, "expected #{injected.class} to normalize to ReadError") do
        GithubApi.new("token", transport: transport, total_timeout: 5, logger: logger).pull_request(
          repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40
        )
      end

      assert_equal "network_failed", error.reason, "expected network_failed for #{injected.class}"
      assert_equal Hive::Web::GithubAuth::TRANSPORT_ERROR_MESSAGE, error.message
      assert_nil error.cause, "translated ReadError must sever raw cause for #{injected.class}"
      [ SENTINEL_HOST, SENTINEL_URL, SENTINEL_TOKEN, injected.class.name ].each do |forbidden|
        refute_includes error.message, forbidden
      end

      assert_equal 1, logger.warnings.length, "expected one warning for #{injected.class}"
      raw_warning = logger.warnings.first
      [ SENTINEL_HOST, SENTINEL_URL, SENTINEL_TOKEN ].each do |forbidden|
        refute_includes raw_warning, forbidden
      end
      assert_equal(
        {
          "event" => Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT,
          "operation" => "github_api_pull_request",
          "reason" => expected_reason,
          "error_class" => injected.class.name
        },
        JSON.parse(raw_warning)
      )
    end
  end

  test "HTTP policy response caps malformed JSON GraphQL errors missing PR and identity mismatch emit no transport diagnostic" do
    cases = [
      [ GithubApi::Response.new(code: "401", headers: {}, body: "{}"), "unauthenticated" ],
      [ GithubApi::Response.new(code: "403", headers: { "x-ratelimit-remaining" => "0" }, body: "{}"),
        "rate_limited" ],
      [ GithubApi::Response.new(code: "429", headers: { "retry-after" => "30" }, body: "{}"),
        "rate_limited" ],
      [ GithubApi::Response.new(code: "502", headers: {}, body: "{}"), "github_http_error" ],
      [ GithubApi::Response.new(code: "200", headers: {}, body: "x" * 4097), "response_oversized" ],
      [ GithubApi::Response.new(code: "200", headers: {}, body: "<html>bad</html>"), "response_invalid" ],
      [ GithubApi::Response.new(code: "200", headers: {},
                                body: JSON.generate("errors" => [ { "message" => "boom" } ])),
        "github_response_error" ],
      [ GithubApi::Response.new(code: "200", headers: {},
                                body: JSON.generate("data" => { "repository" => { "pullRequest" => nil } })),
        "pull_request_missing" ]
    ]

    mismatched_doc = graphql_document
    mismatched_doc.dig("data", "repository", "pullRequest")["number"] = 99
    cases << [ GithubApi::Response.new(code: "200", headers: {}, body: JSON.generate(mismatched_doc)),
               "identity_mismatch" ]

    cases.each do |response, expected_reason|
      logger = RecordingLogger.new
      error = assert_raises(GithubApi::ReadError) do
        GithubApi.new("token", transport: Transport.new(response), logger: logger).pull_request(
          repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40, max_bytes: 4096
        )
      end
      assert_equal expected_reason, error.reason
      assert_empty logger.warnings
    end
  end

  test "malformed transport response and post-transport programming errors are not normalized" do
    malformed_logger = RecordingLogger.new
    assert_raises(NoMethodError) do
      GithubApi.new("token", transport: Transport.new(Object.new), logger: malformed_logger).repositories
    end
    assert_empty malformed_logger.warnings

    bug_response = Object.new
    bug_response.define_singleton_method(:code) { "200" }
    bug_response.define_singleton_method(:headers) { {} }
    bug_response.define_singleton_method(:body) { raise NoMethodError, "undefined method `foo'" }
    bug_logger = RecordingLogger.new
    assert_raises(NoMethodError) do
      GithubApi.new("token", transport: Transport.new(bug_response), logger: bug_logger).pull_request(
        repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40
      )
    end
    assert_empty bug_logger.warnings

    transport_bug_logger = RecordingLogger.new
    assert_raises(NoMethodError) do
      GithubApi.new(
        "token",
        transport: Transport.new { |**| raise NoMethodError, "undefined method `bar'" },
        logger: transport_bug_logger
      ).pull_request(repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40)
    end
    assert_empty transport_bug_logger.warnings
  end

  test "post-transport SystemCallError escapes unchanged without a transport diagnostic" do
    post_error_response = Object.new
    post_error_response.define_singleton_method(:code) { "200" }
    post_error_response.define_singleton_method(:headers) { {} }
    post_error_response.define_singleton_method(:body) do
      raise Errno::ENOENT, "unrelated post-transport filesystem failure"
    end
    logger = RecordingLogger.new

    error = assert_raises(Errno::ENOENT) do
      GithubApi.new("token", transport: Transport.new(post_error_response), logger: logger).pull_request(
        repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40
      )
    end

    assert_match(/unrelated post-transport filesystem failure/, error.message)
    assert_empty logger.warnings
  end

  test "repositories and pull_request use shared transport policy with distinct literal operations" do
    repo_logger = RecordingLogger.new
    repo_error = assert_raises(GithubApi::ReadError) do
      GithubApi.new(
        "token",
        transport: Transport.new { |**| raise Errno::ENETUNREACH, SENTINEL_MESSAGE },
        logger: repo_logger
      ).repositories
    end
    assert_equal "network_failed", repo_error.reason
    assert_equal Hive::Web::GithubAuth::TRANSPORT_ERROR_MESSAGE, repo_error.message
    assert_nil repo_error.cause
    assert_equal(
      {
        "event" => Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT,
        "operation" => "github_api_repositories",
        "reason" => "network_unreachable",
        "error_class" => "Errno::ENETUNREACH"
      },
      JSON.parse(repo_logger.warnings.first)
    )

    pr_logger = RecordingLogger.new
    assert_raises(GithubApi::ReadError) do
      GithubApi.new(
        "token",
        transport: Transport.new { |**| raise OpenSSL::SSL::SSLError, SENTINEL_MESSAGE },
        logger: pr_logger
      ).pull_request(repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40)
    end
    assert_equal "github_api_pull_request", JSON.parse(pr_logger.warnings.first).fetch("operation")

    deadline_logger = RecordingLogger.new
    deadline_error = assert_raises(GithubApi::ReadError) do
      GithubApi.new(
        "token",
        transport: Transport.new { |**| sleep 0.05; GithubApi::Response.new(code: "200", headers: {}, body: "[]") },
        total_timeout: 0.01,
        logger: deadline_logger
      ).repositories
    end
    assert_equal "deadline_exceeded", deadline_error.reason
    assert_equal "GitHub API request exceeded its total deadline", deadline_error.message
    assert_nil deadline_error.cause
    assert_equal(
      {
        "event" => Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT,
        "operation" => "github_api_repositories",
        "reason" => "total_deadline",
        "error_class" => "GithubApi::TotalDeadlineExceeded"
      },
      JSON.parse(deadline_logger.warnings.first)
    )
  end

  test "default constructor emits untagged JSON warning on tagged Rails logger" do
    sentinel_tag = "req-api-sentinel-44"
    log_output = StringIO.new
    tagged_logger = ActiveSupport::TaggedLogging.logger(log_output)
    previous_logger = Rails.logger
    Rails.logger = tagged_logger

    begin
      tagged_logger.tagged(sentinel_tag) do
        Rails.logger.info("before api call")
        assert_raises(GithubApi::ReadError) do
          GithubApi.new("token", transport: Transport.new { |**| raise Net::ReadTimeout, SENTINEL_MESSAGE }).repositories
        end
        Rails.logger.info("after api call")
      end
    ensure
      Rails.logger = previous_logger
    end

    event_lines = log_output.string.lines.select do |line|
      line.include?(Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT)
    end
    assert_equal 1, event_lines.length
    assert_equal(
      {
        "event" => Hive::Web::GithubAuth::TRANSPORT_WARNING_EVENT,
        "operation" => "github_api_repositories",
        "reason" => "read_timeout",
        "error_class" => "Net::ReadTimeout"
      },
      JSON.parse(event_lines.first)
    )
    refute_includes event_lines.first, sentinel_tag
    assert_includes log_output.string, "[#{sentinel_tag}] before api call"
    assert_includes log_output.string, "[#{sentinel_tag}] after api call"
  end

  test "legacy expected and error contexts remain pending and failing" do
    document = graphql_document
    contexts = document.dig(
      "data", "repository", "pullRequest", "commits", "nodes", 0,
      "commit", "statusCheckRollup", "contexts"
    )
    contexts["pageInfo"]["hasNextPage"] = false
    contexts["nodes"] = [
      { "__typename" => "StatusContext", "context" => "awaiting", "state" => "EXPECTED" },
      { "__typename" => "StatusContext", "context" => "broken", "state" => "ERROR" }
    ]
    response = GithubApi::Response.new(code: "200", headers: {}, body: JSON.generate(document))

    checks = GithubApi.new("token", transport: Transport.new(response)).pull_request(
      repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40
    ).fetch("checks")

    assert_equal [ "PENDING", "COMPLETED" ], checks.map { |check| check.fetch("status") }
    assert_equal [ "", "FAILURE" ], checks.map { |check| check.fetch("conclusion") }
  end

  private

  def graphql_document
    {
      "data" => {
        "repository" => {
          "pullRequest" => {
            "number" => 42,
            "url" => "https://github.com/acme/demo/pull/42",
            "state" => "OPEN", "isDraft" => false,
            "title" => "Ship", "body" => "Body",
            "baseRefName" => "main", "baseRefOid" => "c" * 40,
            "headRefName" => "demo", "headRefOid" => "a" * 40,
            "headRepository" => { "nameWithOwner" => "acme/demo" },
            "mergeStateStatus" => "CLEAN", "reviewDecision" => "APPROVED",
            "mergedAt" => nil, "mergeCommit" => nil,
            "commits" => {
              "nodes" => [
                {
                  "commit" => {
                    "statusCheckRollup" => {
                      "contexts" => {
                        "nodes" => [
                          {
                            "__typename" => "CheckRun", "name" => "test",
                            "status" => "COMPLETED", "conclusion" => "SUCCESS",
                            "detailsUrl" => "https://github.com/acme/demo/actions/runs/1"
                          },
                          {
                            "__typename" => "StatusContext", "context" => "legacy",
                            "state" => "PENDING", "targetUrl" => nil
                          }
                        ],
                        "pageInfo" => { "hasNextPage" => true }
                      }
                    }
                  }
                }
              ]
            }
          }
        }
      }
    }
  end
end
