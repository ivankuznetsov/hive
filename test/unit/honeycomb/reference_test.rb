require "test_helper"
require "hive/honeycomb/reference"

class HoneycombReferenceTest < Minitest::Test
  def test_hex_selector_predicate
    assert Hive::Honeycomb::Reference.parse("honeycomb/demo@abcdef0").hex_selector?
    refute Hive::Honeycomb::Reference.parse("honeycomb/demo@1.2.3").hex_selector?
  end

  def test_parses_name_and_optional_selector
    plain = Hive::Honeycomb::Reference.parse("honeycomb/release-notes")
    assert_equal "release-notes", plain.name
    assert_nil plain.selector

    selected = Hive::Honeycomb::Reference.parse("honeycomb/release-notes@1.2.3-beta.1")
    assert_equal "release-notes", selected.name
    assert_equal "1.2.3-beta.1", selected.selector
  end

  def test_rejects_malformed_and_mutable_references
    [ nil, "", "release-notes", "honeycomb/Bad", "honeycomb/a/b", "honeycomb/a@",
      "honeycomb/a@latest", "honeycomb/a@main", "honeycomb/a@1.2", "honeycomb/a@deadbe" ].each do |raw|
      error = assert_raises(Hive::Honeycomb::ReferenceError) do
        Hive::Honeycomb::Reference.parse(raw)
      end
      assert_equal Hive::ExitCodes::USAGE, error.exit_code
    end
  end

  def test_accepts_exact_semver_and_sha_or_digest_selectors
    selectors = [
      "1.2.3", "1.2.3-rc.1+build.9", "abcdef0",
      "a" * 40, "b" * 64
    ]

    selectors.each do |selector|
      assert_equal selector, Hive::Honeycomb::Reference.parse("honeycomb/demo@#{selector}").selector
    end
  end
end
