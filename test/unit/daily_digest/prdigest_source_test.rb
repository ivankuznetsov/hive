require "test_helper"
require "hive/daily_digest/prdigest_source"

class DailyDigestPrdigestSourceTest < Minitest::Test
  include HiveTestHelper
  def test_empty_fleet_needs_no_github_credentials
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*) { flunk "empty fleet must not request a token" }) do
      facts = Hive::DailyDigest::PrdigestSource.new.call(date: "2026-09-15", time_zone: "UTC", projects: [])
      assert_equal [], facts.dig("digest", "repositories")
      assert_equal 0, facts.dig("digest", "totals", "pull_requests")
    end
  end

  def test_repository_scope_is_unique_and_includes_discovered_github_remotes
    projects = [
      { "repository_identity" => "github.com/owner/app" },
      { "repository_identity" => "github.com/owner/app" },
      { "repository_identity" => "gitlab.com/owner/other" },
      { "path" => "/discovered" },
      { "path" => "/no-remote" }
    ]
    captured = nil
    collector = Object.new
    collector.define_singleton_method(:call) do |date:|
      Prdigest::DayDigest.build(date: date, repository_order: [], pulls: [])
    end
    factory = ->(**options) { captured = options; collector }
    discover = ->(path) { path == "/discovered" ? "github.com/owner/discovered" : nil }
    status = Struct.new(:success?).new(true)
    with_replaced_singleton_method(Hive::RepositoryIdentity, :current, discover) do
      with_replaced_singleton_method(Hive::Gh, :capture3, ->(*) { [ "token\n", "", status ] }) do
        with_replaced_singleton_method(Prdigest::Collector, :new, factory) do
          Hive::DailyDigest::PrdigestSource.new.call(date: "2026-09-15", time_zone: "UTC", projects: projects)
        end
      end
    end
    assert_equal [ "owner/app", "owner/discovered" ], captured.fetch(:repositories)
  end

  def test_authentication_and_collection_failures_are_actionable
    source = Hive::DailyDigest::PrdigestSource.new
    status = Struct.new(:success?).new(false)
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*) { [ "", "", status ] }) do
      error = assert_raises(Hive::ConfigError) do
        source.call(date: "2026-09-15", time_zone: "UTC", projects: [ { "repository_identity" => "github.com/owner/app" } ])
      end
      assert_includes error.message, "gh auth login"
    end
    with_replaced_singleton_method(Prdigest::Collector, :new, ->(**_) { raise Prdigest::ConfigError, "collection unavailable" }) do
      error = assert_raises(Hive::UnavailableError) { source.call(date: "2026-09-15", time_zone: "UTC", projects: []) }
      assert_includes error.message, "collection unavailable"
    end
  end
end
