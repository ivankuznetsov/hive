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
end
