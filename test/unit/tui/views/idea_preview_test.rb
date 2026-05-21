require "test_helper"
require "hive/tui/model"
require "hive/tui/views/idea_preview"

class HiveTuiViewsIdeaPreviewTest < Minitest::Test
  include HiveTestHelper

  def model_with(text: "Original idea", slug: "some-slug", cols: 80)
    Hive::Tui::Model.initial.with(
      mode: :idea_preview,
      idea_preview_text: text,
      idea_preview_slug: slug,
      cols: cols
    )
  end

  def render_lines(**kwargs)
    Hive::Tui::Views::IdeaPreview.render(model_with(**kwargs), width: kwargs.fetch(:cols, 80)).lines(chomp: true)
  end

  def test_renders_header_with_slug
    out = Hive::Tui::Views::IdeaPreview.render(model_with(slug: "preview-me"))
    assert_includes out, "Idea for preview-me:"
  end

  def test_renders_original_text_verbatim
    out = Hive::Tui::Views::IdeaPreview.render(model_with(text: "keep [image1] plain"))
    assert_includes out, "keep [image1] plain"
  end

  def test_renders_dismiss_hint
    out = Hive::Tui::Views::IdeaPreview.render(model_with)
    assert out.end_with?(Hive::Tui::Views::IdeaPreview::DISMISS_HINT),
           "dismiss hint must be the final rendered line"
  end

  def test_truncates_long_lines_to_width
    lines = render_lines(text: "x" * 80, cols: 20)

    assert lines.all? { |line| line.length <= 20 },
           "all rendered lines must fit width: #{lines.inspect}"
  end

  def test_caps_visible_rows_for_oversized_text
    text = (1..10).map { |i| "line #{i}" }.join("\n")
    lines = render_lines(text: text)
    body_lines = lines[1...-1]

    assert_operator body_lines.length, :<=, Hive::Tui::Views::IdeaPreview::MAX_VISIBLE_ROWS
  end

  def test_handles_nil_text_gracefully
    lines = render_lines(text: nil, slug: "nil-text")

    assert_equal 2, lines.length
    assert_includes lines.first, "Idea for nil-text:"
    assert_equal Hive::Tui::Views::IdeaPreview::DISMISS_HINT, lines.last
  end
end
