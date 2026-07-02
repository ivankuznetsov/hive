require "test_helper"
require "hive/digest/merged_pr/repo_resolver"

class HiveDigestMergedPrRepoResolverTest < Minitest::Test
  FakeGh = Struct.new(:calls, :responses) do
    def repo_name_with_owner(path, cfg: nil)
      calls << [ path, cfg ]
      value = responses.fetch(path)
      raise value if value.is_a?(Exception)

      value
    end
  end

  def test_explicit_repos_bypass_discovery_and_dedupe
    gh = FakeGh.new([], {})
    resolver = Hive::Digest::MergedPr::RepoResolver.new(
      registry: -> { raise "must not discover" },
      gh: gh,
      logger: nil
    )

    result = resolver.resolve(repos: [ "owner/repo", "owner/repo", "other/repo" ])

    assert_equal [ "owner/repo", "other/repo" ], result.repos
    assert_empty gh.calls
  end

  def test_explicit_repo_must_be_owner_name
    resolver = Hive::Digest::MergedPr::RepoResolver.new(registry: -> { [] }, logger: nil)

    error = assert_raises(Hive::ConfigError) { resolver.resolve(repos: [ "not-a-slug" ]) }

    assert_match(/--repo must be owner\/name/, error.message)
  end

  def test_blank_explicit_repo_is_rejected
    resolver = Hive::Digest::MergedPr::RepoResolver.new(registry: -> { raise "must not discover" }, logger: nil)

    error = assert_raises(Hive::ConfigError) { resolver.resolve(repos: [ "  " ]) }

    assert_match(/--repo must be owner\/name/, error.message)
    assert_match(/"  "/, error.message)
  end

  def test_discovery_drops_failing_project_and_dedupes
    projects = [
      { "name" => "one", "path" => "/tmp/one" },
      { "name" => "bad", "path" => "/tmp/bad" },
      { "name" => "two", "path" => "/tmp/two" }
    ]
    gh = FakeGh.new([], {
      "/tmp/one" => "owner/repo",
      "/tmp/bad" => Hive::GhError.new("no remote"),
      "/tmp/two" => "owner/repo"
    })
    resolver = Hive::Digest::MergedPr::RepoResolver.new(
      registry: -> { projects },
      gh: gh,
      cfg: { "x" => "y" },
      logger: nil
    )

    result = resolver.resolve

    assert_equal [ "owner/repo" ], result.repos
    assert_equal [ [ "/tmp/one", { "x" => "y" } ], [ "/tmp/bad", { "x" => "y" } ], [ "/tmp/two", { "x" => "y" } ] ], gh.calls
    assert_equal 1, result.warnings.size
    assert_match(/dropping project bad/, result.warnings.first)
  end

  def test_malformed_registry_entry_name_is_reported
    resolver = Hive::Digest::MergedPr::RepoResolver.new(
      registry: -> { [ nil ] },
      gh: FakeGh.new([], {}),
      logger: nil
    )

    result = resolver.resolve

    assert_empty result.repos
    assert_equal 1, result.warnings.size
    assert_match(/dropping project <malformed>/, result.warnings.first)
  end
end
