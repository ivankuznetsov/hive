require "test_helper"
require "hive/trailers"

# Direct coverage for Hive::Trailers — the canonical schema for
# hive fix-agent commit trailers. Pinned so adding/renaming a trailer
# in one place (templates / parser / KNOWN list) without the others
# fails this test instead of silently drifting the schema.
class TrailersTest < Minitest::Test
  def test_known_lists_exactly_the_six_trailer_names
    assert_equal %w[
      Hive-Task-Slug
      Hive-Fix-Pass
      Hive-Fix-Findings
      Hive-Triage-Bias
      Hive-Reviewer-Sources
      Hive-Fix-Phase
    ], Hive::Trailers::KNOWN,
                 "KNOWN must list the six canonical trailer names in canonical order"
  end

  def test_schema_version_is_one
    assert_equal 1, Hive::Trailers::SCHEMA_VERSION
  end

  def test_known_returns_true_for_title_case
    assert Hive::Trailers.known?("Hive-Fix-Pass")
  end

  def test_known_is_case_insensitive_lowercase
    assert Hive::Trailers.known?("hive-fix-pass"),
           "trailer match must be case-insensitive (parsers downcase)"
  end

  def test_known_is_case_insensitive_uppercase
    assert Hive::Trailers.known?("HIVE-FIX-PASS")
  end

  def test_known_returns_false_for_unknown_trailer
    refute Hive::Trailers.known?("Hive-Foo")
  end

  def test_known_returns_false_for_empty_string
    refute Hive::Trailers.known?("")
  end

  def test_known_returns_false_for_nil
    refute Hive::Trailers.known?(nil),
           "defensive: nil input must not raise; nil is not a known trailer"
  end
end
