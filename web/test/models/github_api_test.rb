require "test_helper"

class GithubApiTest < ActiveSupport::TestCase
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
    transport = Transport.new do |**|
      sleep 0.05
      GithubApi::Response.new(code: "200", headers: {}, body: JSON.generate(graphql_document))
    end

    error = assert_raises(GithubApi::ReadError) do
      GithubApi.new("token", transport: transport, total_timeout: 0.01).pull_request(
        repository: "github.com/acme/demo", number: 42, expected_head: "a" * 40
      )
    end

    assert_equal "deadline_exceeded", error.reason
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
