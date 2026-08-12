require "json"
require "net/http"
require "uri"
require "hive/gh"

# Minimal GitHub client for the operator's device-flow token. Repository
# listing and the one fixed task-publication GraphQL query are read-only;
# clones still go through `gh` with the token in env.
class GithubApi
  API = "https://api.github.com".freeze
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10
  MAX_PAGES = 3
  PER_PAGE = 100
  PUBLICATION_RESPONSE_BYTES = 256 * 1024
  PUBLICATION_CHECKS = 100

  Response = Data.define(:code, :body, :headers)

  class ReadError < Hive::Error
    attr_reader :reason, :retry_after

    def initialize(reason, message, retry_after: nil)
      @reason = reason.to_s
      @retry_after = retry_after
      super(message)
    end
  end

  # Kept in lockstep with Hive::Web::GithubAuth::NETWORK_ERRORS — drift here
  # already shipped one blank 500 (EHOSTUNREACH missing while the auth class
  # had it).
  NETWORK_ERRORS = Hive::Web::GithubAuth::NETWORK_ERRORS

  def initialize(token, transport: nil, open_timeout: OPEN_TIMEOUT,
                 read_timeout: READ_TIMEOUT)
    @token = token
    @transport = transport || method(:perform_request)
    @open_timeout = open_timeout
    @read_timeout = read_timeout
  end

  # The operator's repositories, most recently pushed first. Paginated up to
  # MAX_PAGES * PER_PAGE; Hive web is a single-operator UI, not a mirror of
  # GitHub, so an enormous account simply sees its most recent 300.
  def repositories
    (1..MAX_PAGES).each_with_object([]) do |page, repos|
      batch = get("/user/repos", per_page: PER_PAGE, page: page, sort: "pushed")
      repos.concat(batch)
      break repos if batch.size < PER_PAGE
    end
  end

  # One allowlisted query for one already-validated PR identity. It returns
  # normalized plain data and never follows repository, URL, or field choices
  # supplied by the browser.
  def pull_request(repository:, number:, expected_head:,
                   max_bytes: PUBLICATION_RESPONSE_BYTES,
                   checks_limit: PUBLICATION_CHECKS)
    host, owner, name = canonical_repository(repository)
    number = Integer(number)
    raise ReadError.new("identity_invalid", "pull request number must be positive") unless number.positive?
    expected_head = expected_head.to_s.downcase
    unless expected_head.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/)
      raise ReadError.new("identity_invalid", "expected head must be a full commit OID")
    end
    checks_limit = Integer(checks_limit)
    unless checks_limit.positive? && checks_limit <= PUBLICATION_CHECKS
      raise ReadError.new("identity_invalid", "checks limit is invalid")
    end

    uri = URI("#{API}/graphql")
    request = Net::HTTP::Post.new(uri)
    request["Accept"] = "application/vnd.github+json"
    request["Authorization"] = "Bearer #{@token}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(
      "query" => publication_query,
      "variables" => {
        "owner" => owner, "name" => name, "number" => number,
        "checks" => checks_limit
      }
    )
    document = request_json(uri, request, max_bytes: Integer(max_bytes))
    if Array(document["errors"]).any?
      raise ReadError.new("github_response_error", "GitHub publication query returned errors")
    end
    pr = document.dig("data", "repository", "pullRequest")
    raise ReadError.new("pull_request_missing", "pull request is unavailable") unless pr.is_a?(Hash)
    unless Integer(pr["number"], exception: false) == number
      raise ReadError.new("identity_mismatch", "GitHub returned a different pull request")
    end

    rollup = Array(pr.dig("commits", "nodes")).last&.dig("commit", "statusCheckRollup")
    contexts = rollup.is_a?(Hash) ? rollup["contexts"] : nil
    checks = Array(contexts && contexts["nodes"]).first(checks_limit).filter_map do |node|
      normalize_check(node)
    end
    head_oid = valid_oid(pr["headRefOid"])
    {
      "repository" => "#{host}/#{owner}/#{name}".downcase,
      "number" => number,
      "url" => pr["url"].to_s,
      "state" => pr["state"].to_s,
      "is_draft" => pr["isDraft"] == true,
      "title" => pr["title"].to_s,
      "body" => pr["body"].to_s,
      "base_branch" => pr["baseRefName"].to_s,
      "base_oid" => valid_oid(pr["baseRefOid"]),
      "head_branch" => pr["headRefName"].to_s,
      "head_oid" => head_oid,
      "expected_head" => expected_head,
      "head_matches" => head_oid == expected_head,
      "head_branch_present" => pr["headRepository"].is_a?(Hash),
      "merge_state" => pr["mergeStateStatus"].to_s,
      "review_decision" => pr["reviewDecision"].to_s,
      "merged_at" => pr["mergedAt"].to_s,
      "merge_commit_oid" => valid_oid(pr.dig("mergeCommit", "oid")),
      "checks" => checks,
      "checks_truncated" => contexts&.dig("pageInfo", "hasNextPage") == true ||
                            Array(contexts && contexts["nodes"]).length > checks.length
    }
  rescue ArgumentError, TypeError
    raise ReadError.new("identity_invalid", "publication identity is invalid")
  end

  private

  def get(path, **query)
    uri = URI("#{API}#{path}")
    uri.query = URI.encode_www_form(query)
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/vnd.github+json"
    req["Authorization"] = "Bearer #{@token}"
    request_json(uri, req)
  end

  def request_json(uri, request, max_bytes: nil)
    response = @transport.call(
      uri: uri, request: request,
      open_timeout: @open_timeout, read_timeout: @read_timeout,
      max_bytes: max_bytes
    )
    code = Integer(response.code)
    retry_after = response.headers.to_h["retry-after"] || response.headers.to_h["Retry-After"]
    remaining = response.headers.to_h["x-ratelimit-remaining"] ||
                response.headers.to_h["X-RateLimit-Remaining"]
    if code == 429 || (code == 403 && remaining.to_s == "0")
      raise ReadError.new(
        "rate_limited", "GitHub API rate limit reached", retry_after: retry_after
      )
    end
    raise ReadError.new("unauthenticated", "GitHub authentication was rejected") if code == 401
    unless code.between?(200, 299)
      raise ReadError.new("github_http_error", "GitHub API request failed (HTTP #{code})")
    end
    if max_bytes && response.body.to_s.bytesize > max_bytes
      raise ReadError.new("response_oversized", "GitHub response exceeded its byte limit")
    end

    JSON.parse(response.body)
  rescue JSON::ParserError
    raise ReadError.new("response_invalid", "GitHub API returned an unparseable response")
  rescue *NETWORK_ERRORS => e
    raise ReadError.new("network_failed", "could not reach GitHub (#{e.class})")
  end

  def perform_request(uri:, request:, open_timeout:, read_timeout:, max_bytes:)
    body = +"".b
    code = nil
    headers = {}
    Net::HTTP.start(
      uri.host, uri.port, use_ssl: true,
      open_timeout: open_timeout, read_timeout: read_timeout
    ) do |http|
      http.request(request) do |response|
        code = response.code
        response.each_header { |key, value| headers[key] = value }
        response.read_body do |chunk|
          body << chunk
          if max_bytes && body.bytesize > max_bytes
            raise ReadError.new("response_oversized", "GitHub response exceeded its byte limit")
          end
        end
      end
    end
    Response.new(code: code, body: body, headers: headers)
  end

  def canonical_repository(repository)
    host, owner, name = repository.to_s.downcase.split("/", 3)
    host = Hive::Gh::RepositoryIdentity.validated_github_host(host).downcase
    unless host == "github.com"
      raise ReadError.new("identity_invalid", "publication host is not allowlisted")
    end
    slug = Hive::Gh::RepositoryIdentity.validated_repository_slug("#{owner}/#{name}").downcase
    [ host, *slug.split("/", 2) ]
  rescue Hive::GhError
    raise ReadError.new("identity_invalid", "publication repository is invalid")
  end

  def valid_oid(value)
    oid = value.to_s.downcase
    oid.match?(/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\z/) ? oid : nil
  end

  def normalize_check(node)
    return unless node.is_a?(Hash)

    case node["__typename"]
    when "CheckRun"
      {
        "name" => node["name"].to_s,
        "status" => node["status"].to_s,
        "conclusion" => node["conclusion"].to_s,
        "url" => node["detailsUrl"].to_s
      }
    when "StatusContext"
      state = node["state"].to_s
      {
        "name" => node["context"].to_s,
        "status" => state == "PENDING" ? "PENDING" : "COMPLETED",
        "conclusion" => state,
        "url" => node["targetUrl"].to_s
      }
    end
  end

  def publication_query
    <<~GRAPHQL
      query HiveTaskPublication($owner: String!, $name: String!, $number: Int!, $checks: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            number url state isDraft title body
            baseRefName baseRefOid headRefName headRefOid
            headRepository { nameWithOwner }
            mergeStateStatus reviewDecision mergedAt mergeCommit { oid }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: $checks) {
                      pageInfo { hasNextPage }
                      nodes {
                        __typename
                        ... on CheckRun { name status conclusion detailsUrl }
                        ... on StatusContext { context state targetUrl }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL
  end
end
