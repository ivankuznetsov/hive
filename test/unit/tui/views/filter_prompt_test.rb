require "test_helper"
require "hive/tui/model"
require "hive/tui/views/filter_prompt"

class HiveTuiViewsFilterPromptTest < Minitest::Test
  include HiveTestHelper

  def model_with(buffer: "", cols: 80)
    Hive::Tui::Model.initial.with(mode: :filter, filter_buffer: buffer, cols: cols)
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

  # Long buffers slide so the cursor stays at the right edge — without
  # this the rendered line overflows the terminal and disappears off
  # the right side. The visible window shows the TAIL of the buffer.
  def test_long_buffer_slides_to_show_tail_within_cols
    long = ("a" * 50) + ("z" * 50) # 100 chars; at width=20 only the trailing tail fits
    out = Hive::Tui::Views::FilterPrompt.render(model_with(buffer: long, cols: 20))
    refute_includes out, ("a" * 50),
                    "leading 50 a's must NOT appear; sliding-window keeps only the tail"
    assert_includes out, "zzzz", "trailing portion of buffer must be visible"
  end

  def test_buffer_within_cols_renders_in_full
    out = Hive::Tui::Views::FilterPrompt.render(model_with(buffer: "auth-token", cols: 80))
    assert_includes out, "auth-token", "buffer that fits within cols must render verbatim"
  end

  def test_explicit_width_kwarg_overrides_model_cols
    out = Hive::Tui::Views::FilterPrompt.render(
      model_with(buffer: "x" * 50, cols: 200),
      width: 10
    )
    refute_match(/x{50}/, out, "width: kwarg must clamp regardless of model.cols")
  end
end
