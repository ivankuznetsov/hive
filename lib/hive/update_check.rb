require "net/http"
require "json"
require "hive"

module Hive
  # Queries the latest published GitHub release and reports whether the running
  # version is behind. Pure query, no side effects, no persistence (state lives
  # in Hive::UpdateCheck::State). Mirrors install.sh's `latest_version` probe.
  #
  # NEVER raises: every failure path (network, HTTP error, malformed JSON,
  # unparseable version) returns nil. The daemon calls this on a tick and must
  # not crash because GitHub is unreachable or rate-limiting.
  module UpdateCheck
    API_URL = "https://api.github.com/repos/#{Hive::REPO_OWNER}/#{Hive::REPO_NAME}/releases/latest".freeze

    # Base URL of the releases-latest endpoint. `HIVE_RELEASES_API_URL` overrides
    # the GitHub default — primarily so an e2e can point a real process at a
    # local stub server, but also a seam for forks / GitHub Enterprise /
    # air-gapped mirrors. An exported-but-empty value is treated as unset.
    def self.releases_url
      override = ENV["HIVE_RELEASES_API_URL"]
      override.nil? || override.empty? ? API_URL : override
    end

    Result = Data.define(:current, :latest, :behind) do
      def behind? = behind
    end

    module_function

    # @param current [String] the running version (bare semver)
    # @param http [#call, nil] injectable seam for tests: called with the URL,
    #   returns the response body string (or raises to simulate failure)
    # @return [Result, nil] nil on any failure
    def latest(current: Hive::VERSION, http: nil, timeout: 5)
      tag = fetch_latest_tag(http: http, timeout: timeout)
      return nil if tag.nil? || tag.empty?

      latest_version = tag.sub(/\Av/, "")
      Result.new(current: current, latest: latest_version, behind: newer?(latest_version, current))
    rescue StandardError
      nil
    end

    def fetch_latest_tag(http: nil, timeout: 5)
      url = releases_url
      body = http ? http.call(url) : http_get(url, timeout: timeout)
      return nil if body.nil?

      JSON.parse(body)["tag_name"]
    rescue StandardError
      nil
    end

    def http_get(url, timeout:)
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                            open_timeout: timeout, read_timeout: timeout) do |http|
        req = Net::HTTP::Get.new(uri)
        req["Accept"] = "application/vnd.github+json"
        req["User-Agent"] = "hive-update-check"
        http.request(req)
      end
      res.is_a?(Net::HTTPSuccess) ? res.body : nil
    end

    # True iff `latest` is a strictly newer release than `current`. Never
    # downgrades (local dev builds ahead of the latest tag are not "behind").
    def newer?(latest_version, current)
      Gem::Version.new(latest_version) > Gem::Version.new(current)
    rescue ArgumentError
      false
    end
  end
end
