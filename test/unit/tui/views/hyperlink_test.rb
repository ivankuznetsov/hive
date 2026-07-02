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

  # A PR-shaped but non-http(s) href (here `ftp://…/pull/12`) DOES yield a PR
  # token via Hive::Pr.number (`#12`) yet fails the valid_http_url? gate, so
  # the link builder must drop it — symmetric with Hive::Bot::Format
  # .html_pr_link returning nil for the same href. The `javascript:` case is
  # pinned above; this guards the second non-http scheme the gate rejects.
  def test_osc8_rejects_pr_shaped_non_http_url
    assert_equal "#12", Hive::Tui::Views::Hyperlink.osc8("#12", "ftp://h/o/r/pull/12", enabled: true)
  end

  # Direct splice contract (otherwise only exercised indirectly via
  # pr_cell/display_identity_with_pr): the token at [offset, offset+length)
  # is wrapped, while leading padding AND trailing text stay OUTSIDE the link
  # so the cell keeps its visible width. Behavior pinned via the osc8 builder
  # so an OSC 8 framing change doesn't break the assertion.
  def test_splice_wraps_token_and_keeps_padding_and_trailing_text_outside_link
    url = "https://github.com/o/r/pull/561"
    padded = "  #561 tail"

    out = Hive::Tui::Views::Hyperlink.splice(padded, 2, 4, url, enabled: true)

    link = Hive::Tui::Views::Hyperlink.osc8("#561", url, enabled: true)
    assert_equal "  #{link} tail", out,
                 "leading padding and trailing text stay outside the spliced OSC 8 link"
  end

  def test_splice_returns_padded_unchanged_when_disabled
    padded = "  #561 tail"

    assert_equal padded,
                 Hive::Tui::Views::Hyperlink.splice(padded, 2, 4, "https://github.com/o/r/pull/561", enabled: false),
                 "a disabled (non-tty) splice must return the padded string byte-for-byte"
  end

  def test_splice_returns_padded_unchanged_for_rejected_url
    padded = "  #12 tail"

    assert_equal padded,
                 Hive::Tui::Views::Hyperlink.splice(padded, 2, 3, "ftp://h/o/r/pull/12", enabled: true),
                 "a PR-shaped non-http URL is rejected by osc8, so splice returns the padded string unchanged"
  end
end
