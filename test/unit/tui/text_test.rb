require "test_helper"
require "hive/tui/text"

class HiveTuiTextTest < Minitest::Test
  def test_sanitize_strips_ansi_and_replaces_control_chars
    out = Hive::Tui::Text.sanitize("\e[2Jhello\nworld\e[31m!\e[0m")

    assert_equal "hello?world!", out
  end

  # Regression: Regexp matching validates the receiver's encoding, so a
  # string tagged UTF-8 while carrying invalid bytes (subprocess stderr,
  # exception messages) used to raise ArgumentError before any
  # sanitisation happened. Scrubbing must come first.
  def test_sanitize_scrubs_invalid_byte_sequences_instead_of_raising
    input = "stderr: \xFF".dup.force_encoding(Encoding::UTF_8)

    refute input.valid_encoding?, "precondition: input must be invalid UTF-8"

    out = Hive::Tui::Text.sanitize(input)

    assert out.valid_encoding?
    assert_includes out, "stderr:"
    refute_includes out, "\xFF"
  end

  def test_sanitize_is_idempotent
    once = Hive::Tui::Text.sanitize("a\e[1;2mb\x7fc\u0000d".dup.force_encoding(Encoding::UTF_8))

    assert_equal once, Hive::Tui::Text.sanitize(once)
  end

  def test_sanitize_returns_empty_string_for_nil_or_non_string_input
    assert_equal "", Hive::Tui::Text.sanitize(nil)
    assert_equal "42", Hive::Tui::Text.sanitize(42)
  end
end
