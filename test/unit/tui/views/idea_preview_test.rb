require "test_helper"
require "hive/tui/model"
require "hive/tui/views/idea_preview"

class HiveTuiViewsIdeaPreviewTest < Minitest::Test
  include HiveTestHelper

  UNSET = Object.new.freeze

  def info_state(stage: "2-brainstorm", slug: "some-slug", created_at: "2026-05-22T22:40:00Z",
                 original_text: "Original idea", folder_path: UNSET, latest_log_path: UNSET,
                 stage_extra: nil)
    folder_path = "/home/asterio/Dev/hive/.hive-state/stages/#{stage}/#{slug}" if folder_path.equal?(UNSET)
    latest_log_path = "/home/asterio/Dev/hive/.hive-state/logs/#{slug}/run.log" if latest_log_path.equal?(UNSET)
    Hive::Tui::Model::InfoPanelState.new(
      slug: slug,
      stage: stage,
      created_at: created_at,
      original_text: original_text,
      folder_path: folder_path,
      latest_log_path: latest_log_path,
      stage_extra: stage_extra
    )
  end

  def model_with(state: info_state, cols: 80, rows: 24)
    Hive::Tui::Model.initial.with(mode: :idea_preview, info_panel_state: state, cols: cols, rows: rows)
  end

  def render(state: info_state, cols: 80, rows: 24, height: rows - 1)
    Hive::Tui::Views::IdeaPreview.render(model_with(state: state, cols: cols, rows: rows), width: cols, height: height)
  end

  def rendered_lines(**kwargs)
    render(**kwargs).lines(chomp: true)
  end

  def test_returns_empty_string_without_panel_state
    out = Hive::Tui::Views::IdeaPreview.render(model_with(state: nil))

    assert_equal "", out
  end

  def test_renders_header_with_slug_and_stage
    out = render(state: info_state(slug: "preview-me", stage: "2-brainstorm"))

    assert_includes out, "Info: preview-me"
    assert_includes out, "[stage: 2-brainstorm]"
  end

  def test_renders_common_fields
    state = info_state(
      created_at: "2026-05-22T22:40:00Z",
      folder_path: "/tmp/project/.hive-state/stages/2-brainstorm/some-slug",
      latest_log_path: "/tmp/project/.hive-state/logs/some-slug/brainstorm.log"
    )

    out = render(state: state)

    assert_includes out, "created_at:"
    assert_includes out, "2026-05-22T22:40:00Z"
    assert_includes out, "folder:"
    assert_includes out, "/tmp/project/.hive-state/stages/2-brainstorm/some-slug"
    assert_includes out, "latest log:"
    assert_includes out, "/tmp/project/.hive-state/logs/some-slug/brainstorm.log"
  end

  def test_renders_unknown_common_field_fallbacks
    out = render(state: info_state(created_at: nil, folder_path: nil, latest_log_path: nil))

    assert_includes out, "created_at:  (unknown)"
    assert_includes out, "folder:      (unknown)"
    assert_includes out, "latest log:  (none)"
  end

  def test_renders_original_idea_section_with_wrapped_text
    out = render(state: info_state(original_text: "keep [image1] plain\nand wrap"))

    assert_includes out, "Original idea"
    assert_includes out, "keep [image1] plain"
    assert_includes out, "and wrap"
  end

  def test_renders_brainstorm_extra_section
    out = render(state: info_state(stage: "2-brainstorm", stage_extra: "# Brainstorm\nQ1"))

    assert_includes out, "brainstorm.md"
    assert_includes out, "# Brainstorm"
    assert_includes out, "Q1"
  end

  def test_renders_plan_extra_section
    out = render(state: info_state(stage: "3-plan", stage_extra: "# Plan\nIU1"))

    assert_includes out, "plan.md"
    assert_includes out, "# Plan"
    assert_includes out, "IU1"
  end

  def test_renders_execute_log_extra_section
    out = render(state: info_state(stage: "4-execute", stage_extra: "line one\nline two"))

    assert_includes out, "execute log"
    assert_includes out, "line one"
    assert_includes out, "line two"
  end

  def test_inbox_without_extra_renders_no_extra_section
    out = render(state: info_state(stage: "1-inbox", stage_extra: nil))

    refute_includes out, "brainstorm.md"
    refute_includes out, "plan.md"
    refute_includes out, "execute log"
  end

  def test_renders_close_hint_as_final_visible_line
    lines = rendered_lines(state: info_state)

    assert lines.last.end_with?(Hive::Tui::Views::IdeaPreview::DISMISS_HINT),
           "close hint must be final rendered line: #{lines.last.inspect}"
  end

  def test_truncates_long_lines_to_width
    lines = rendered_lines(
      state: info_state(
        slug: "x" * 80,
        original_text: "y" * 80,
        folder_path: "/tmp/#{"z" * 80}",
        latest_log_path: "/tmp/#{"l" * 80}"
      ),
      cols: 30,
      height: 12
    )

    assert lines.all? { |line| line.length <= 30 },
           "all rendered lines must fit width: #{lines.inspect}"
  end

  def test_truncates_extra_block_before_common_block_when_height_overflows
    extra = (1..20).map { |i| "extra line #{i}" }.join("\n")
    out = render(state: info_state(original_text: "common survives", stage_extra: extra), height: 13)

    assert_includes out, "created_at:"
    assert_includes out, "folder:"
    assert_includes out, "latest log:"
    assert_includes out, "Original idea"
    assert_includes out, "common survives"
    assert_includes out, "brainstorm.md"
    assert_includes out, "…"
    refute_includes out, "extra line 20"
  end
end
