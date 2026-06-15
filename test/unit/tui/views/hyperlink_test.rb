require "test_helper"
require "hive/tui/views/hyperlink"

class HiveTuiViewsHyperlinkTest < Minitest::Test
  def test_osc8_wraps_valid_http_url_when_enabled
    output = Hive::Tui::Views::Hyperlink.osc8("#561", "https://github.com/o/r/pull/561", enabled: true)

    assert_equal "\e]8;;https://github.com/o/r/pull/561\e\\#561\e]8;;\e\\", output
  end

  def test_osc8_passthrough_when_disabled_or_invalid
    assert_equal "#561", Hive::Tui::Views::Hyperlink.osc8("#561", "https://github.com/o/r/pull/561", enabled: false)
    assert_equal "#561", Hive::Tui::Views::Hyperlink.osc8("#561", "javascript:alert(1)", enabled: true)
    assert_equal "#561", Hive::Tui::Views::Hyperlink.osc8("#561", "", enabled: true)
  end

  def test_osc8_strips_control_chars_from_url
    output = Hive::Tui::Views::Hyperlink.osc8("#561", "https://github.com/o/r/pull/561\e[31m", enabled: true)

    refute_match(/\e\[/, output)
    assert_includes output, "https://github.com/o/r/pull/561"
  end

  # Pins the contract for an INTERIOR control char in the URL: Text.sanitize
  # REPLACES it with `?` (to keep TUI column width one-cell-per-char), so
  # osc8 links to the `?`-substituted href rather than rejecting it. This
  # deliberately diverges from Hive::Bot::Format.html_pr_link, which DELETES
  # the byte (no column constraint) and then returns nil because the mangled
  # URL no longer parses as a PR. Input here is trusted-local (pr.md, then
  # .strip'd), so neither path is a security risk — this just makes the
  # divergence a deliberate, regression-pinned decision.
  def test_osc8_replaces_interior_control_char_and_still_links
    output = Hive::Tui::Views::Hyperlink.osc8("#561", "https://github.com/o/r/pull/561\nx", enabled: true)

    assert_equal "\e]8;;https://github.com/o/r/pull/561?x\e\\#561\e]8;;\e\\", output
  end
end
