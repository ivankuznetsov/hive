require "test_helper"
require "hive/tui/model"
require "hive/tui/views/filter_prompt"

class HiveTuiViewsFilterPromptTest < Minitest::Test
  include HiveTestHelper

  def model_with(buffer: "")
    Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: buffer)
  end

  def test_empty_buffer_renders_just_prompt_and_cursor
    out = Hive::Tui::Views::FilterPrompt.render(model_with(buffer: ""))
    assert_match(/\A\//, out, "rendered prompt must start with '/'")
    assert_includes out, " ", "cursor block (rendered as space) must be present"
  end

  def test_buffer_appears_after_prompt
    out = Hive::Tui::Views::FilterPrompt.render(model_with(buffer: "auth"))
    assert_match(%r{\A/auth}, out, "buffer must appear directly after the slash prompt")
  end

  def test_long_buffer_renders_in_full
    long = "a" * 100
    out = Hive::Tui::Views::FilterPrompt.render(model_with(buffer: long))
    assert_includes out, long, "long buffers render verbatim — the bottom row composes truncation"
  end
end
