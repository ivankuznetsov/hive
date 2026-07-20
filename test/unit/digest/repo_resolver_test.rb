require "test_helper"
require "hive/digest/repo_resolver"

class HiveDigestRepoResolverTest < Minitest::Test
  FakeGh = Struct.new(:calls, :responses) do
    def repository_identity(path, cfg: nil)
      calls << [ path, cfg ]
      value = responses.fetch(path)
      raise value if value.is_a?(Exception)

      value
    end
  end

  def test_discovers_registered_targets_with_host_and_filters_case_insensitively
    projects = [
      { "name" => "Alpha", "path" => "/tmp/alpha" },
      { "name" => "Duplicate", "path" => "/tmp/duplicate" },
      { "name" => "Enterprise", "path" => "/tmp/enterprise" }
    ]
    gh = FakeGh.new([], {
      "/tmp/alpha" => { "repository" => "Owner/Alpha", "host" => "github.com" },
      "/tmp/duplicate" => { "repository" => "owner/alpha", "host" => "github.com" },
      "/tmp/enterprise" => { "repository" => "Corp/App", "host" => "github.example.com" }
    })
    resolver = Hive::Digest::RepoResolver.new(registry: -> { projects }, gh: gh, cfg: { "x" => 1 }, logger: nil)

    result = resolver.resolve(repos: [ "corp/app" ])

    assert_equal [ "Corp/App" ], result.targets.map(&:repository)
    assert_equal [ "github.example.com" ], result.targets.map(&:host)
    assert_equal [ "Enterprise" ], result.targets.map(&:project_name)
    assert_equal 3, gh.calls.size, "--repo filters registered targets after discovery"
  end

  def test_partial_discovery_keeps_survivors_and_structured_warning
    projects = [
      { "name" => "Broken", "path" => "/tmp/broken" },
      { "name" => "Working", "path" => "/tmp/working" }
    ]
    gh = FakeGh.new([], {
      "/tmp/broken" => Hive::GhError.new("no remote"),
      "/tmp/working" => { "repository" => "owner/repo", "host" => "github.com" }
    })

    result = Hive::Digest::RepoResolver.new(registry: -> { projects }, gh: gh, logger: nil).resolve

    assert_equal [ "owner/repo" ], result.targets.map(&:repository)
    assert_equal "repository_discovery_failed", result.warnings.first.kind
    assert_equal "Broken", result.warnings.first.repository
    refute_includes result.warnings.first.message, "/tmp/broken"
  end

  def test_rejects_empty_registry_and_all_failed_discovery
    empty = Hive::Digest::RepoResolver.new(registry: -> { [] }, logger: nil)
    assert_match(/no registered GitHub repositories/, assert_raises(Hive::ConfigError) { empty.resolve }.message)

    failed = Hive::Digest::RepoResolver.new(
      registry: -> { [ { "name" => "Broken", "path" => "/tmp/broken" } ] },
      gh: FakeGh.new([], { "/tmp/broken" => Hive::GhError.new("no remote") }),
      logger: nil
    )
    assert_match(/no registered GitHub repositories/, assert_raises(Hive::ConfigError) { failed.resolve }.message)
  end

  def test_rejects_blank_invalid_and_unknown_filters
    resolver = Hive::Digest::RepoResolver.new(
      registry: -> { [ { "name" => "Alpha", "path" => "/tmp/alpha" } ] },
      gh: FakeGh.new([], {
        "/tmp/alpha" => { "repository" => "owner/alpha", "host" => "github.com" }
      }),
      logger: nil
    )

    assert_match(/owner\/name/, assert_raises(Hive::ConfigError) { resolver.resolve(repos: [ "  " ]) }.message)
    assert_match(/owner\/name/, assert_raises(Hive::ConfigError) { resolver.resolve(repos: [ "invalid" ]) }.message)
    assert_match(/not registered/, assert_raises(Hive::ConfigError) { resolver.resolve(repos: [ "owner/missing" ]) }.message)
    assert_match(/not registered/, assert_raises(Hive::ConfigError) {
      resolver.resolve(repos: [ "owner/alpha", "owner/missing" ])
    }.message)
  end

  def test_deduplicates_case_variants_without_reading_hive_state
    projects = [
      { "name" => "First", "path" => "/tmp/first" },
      { "name" => "Second", "path" => "/tmp/second" }
    ]
    gh = FakeGh.new([], {
      "/tmp/first" => { "repository" => "Owner/Repo", "host" => "github.com" },
      "/tmp/second" => { "repository" => "owner/repo", "host" => "GITHUB.com" }
    })

    result = Hive::Digest::RepoResolver.new(registry: -> { projects }, gh: gh, logger: nil).resolve

    assert_equal [ "First" ], result.targets.map(&:project_name)
  end
end
