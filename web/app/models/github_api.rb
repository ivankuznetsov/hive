# Minimal GitHub REST client for the operator's device-flow token. Read-only
# listing for the Repos page; clones go through `gh` with the token in env.
class GithubApi
  API = "https://api.github.com".freeze
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10
  MAX_PAGES = 3
  PER_PAGE = 100

  # Kept in lockstep with Hive::Web::GithubAuth::NETWORK_ERRORS — drift here
  # already shipped one blank 500 (EHOSTUNREACH missing while the auth class
  # had it).
  NETWORK_ERRORS = Hive::Web::GithubAuth::NETWORK_ERRORS

  def initialize(token)
    @token = token
  end

  # The operator's repositories, most recently pushed first. Paginated up to
  # MAX_PAGES * PER_PAGE; hivebox is a single-operator box, not a mirror of
  # GitHub, so an enormous account simply sees its most recent 300.
  def repositories
    (1..MAX_PAGES).each_with_object([]) do |page, repos|
      batch = get("/user/repos", per_page: PER_PAGE, page: page, sort: "pushed")
      repos.concat(batch)
      break repos if batch.size < PER_PAGE
    end
  end

  private

  def get(path, **query)
    uri = URI("#{API}#{path}")
    uri.query = URI.encode_www_form(query)
    req = Net::HTTP::Get.new(uri)
    req["Accept"] = "application/vnd.github+json"
    req["Authorization"] = "Bearer #{@token}"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true,
                          open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |h| h.request(req) }
    raise Hive::Error, "GitHub API #{path} failed (HTTP #{res.code})" unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  rescue JSON::ParserError
    raise Hive::Error, "GitHub API returned an unparseable response"
  rescue *NETWORK_ERRORS => e
    raise Hive::Error, "could not reach GitHub (#{e.class}: #{e.message})"
  end
end
