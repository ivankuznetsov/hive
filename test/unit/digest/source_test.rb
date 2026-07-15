require "test_helper"
require "hive/digest/source"

class HiveDigestSourceTest < Minitest::Test
  Source = Hive::Digest::Source

  def test_defaults_to_merged_prs_when_source_is_absent_or_blank
    assert_equal Source::MERGED_PRS, Source.resolve
    assert_equal Source::MERGED_PRS, Source.resolve(configured: "")
  end

  def test_configured_source_supplies_the_default
    assert_equal Source::SHIPPED, Source.resolve(configured: "shipped")
    assert_equal Source::MERGED_PRS, Source.resolve(configured: "merged-prs")
  end

  def test_explicit_source_wins_over_configured_source
    assert_equal Source::MERGED_PRS,
                 Source.resolve(explicit: "merged-prs", configured: "shipped")
    assert_equal Source::SHIPPED,
                 Source.resolve(explicit: "shipped", configured: "merged-prs")
  end

  def test_repo_implies_merged_prs_when_source_is_omitted
    assert_equal Source::MERGED_PRS,
                 Source.resolve(repos: [ "owner/repo" ], configured: "shipped")
  end

  def test_explicit_shipped_conflicts_with_repo_scope
    error = assert_raises(Hive::ConfigError) do
      Source.resolve(explicit: "shipped", repos: [ "owner/repo" ])
    end

    assert_match(/--source shipped cannot be combined with --repo/, error.message)
  end

  def test_unknown_explicit_and_configured_sources_name_allowed_values
    explicit_error = assert_raises(Hive::ConfigError) { Source.resolve(explicit: "unknown") }
    config_error = assert_raises(Hive::ConfigError) { Source.resolve(configured: "unknown") }

    [ explicit_error, config_error ].each do |error|
      assert_match(/merged-prs/, error.message)
      assert_match(/shipped/, error.message)
    end
    assert_match(/--source/, explicit_error.message)
    assert_match(/digest\.source/, config_error.message)
  end

  def test_schema_mapping_matches_the_resolved_source
    assert_equal "hive-merged-pr-digest", Source.schema_for(Source::MERGED_PRS)
    assert_equal "hive-digest", Source.schema_for(Source::SHIPPED)
  end

  def test_argv_schema_selection_uses_the_same_precedence
    assert_equal "hive-merged-pr-digest", Source.schema_for_argv([], configured: nil)
    assert_equal "hive-digest", Source.schema_for_argv([], configured: "shipped")
    assert_equal "hive-merged-pr-digest",
                 Source.schema_for_argv(%w[--repo owner/repo], configured: "shipped")
    assert_equal "hive-digest",
                 Source.schema_for_argv(%w[--source shipped --repo owner/repo], configured: nil)
    assert_equal "hive-merged-pr-digest",
                 Source.schema_for_argv(%w[--source=merged-prs], configured: "shipped")
  end
end
