require "test_helper"
require "hive/display_name/sanitizer"

class DisplayNameSanitizerTest < Minitest::Test
  def test_strips_quotes_markdown_newlines_and_trailing_punctuation
    assert_equal "Add inbox filter",
                 Hive::DisplayName::Sanitizer.sanitize(%("**Add inbox\nfilter.**"))
  end

  def test_empty_returns_nil
    assert_nil Hive::DisplayName::Sanitizer.sanitize(" \n * ")
  end

  def test_truncates_long_titles
    name = Hive::DisplayName::Sanitizer.sanitize("word " * 30)
    assert_operator name.length, :<=, Hive::DisplayName::Sanitizer::MAX_LENGTH
  end
end
