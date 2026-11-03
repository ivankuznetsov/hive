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
    out = render(state: info_state(original_text: "common survives", stage_extra: extra), height: 14)

    assert_includes out, "created_at:"
    assert_includes out, "folder:"
    assert_includes out, "latest log:"
    assert_includes out, "Original idea"
    assert_includes out, "common survives"
    assert_includes out, "brainstorm.md"
    assert_includes out, "…"
    refute_includes out, "extra line 20"
  end

  def test_long_original_text_cannot_suppress_stage_extra_title
    long_text = (1..40).map { |i| "idea body line #{i}" }.join("\n")
    out = render(state: info_state(original_text: long_text, stage_extra: "# Brainstorm body"), height: 13)

    assert_includes out, "brainstorm.md",
                    "stage_extra title block must survive a long original_text per IU3 contract"
  end

  def test_wraps_original_and_stage_extra_by_cells_without_horizontal_ellipsis
    source = "一二三四五六七八九十"
    lines = rendered_lines(state: info_state(original_text: source, stage_extra: source), cols: 10, height: 16)

    assert_equal [ "一二三四五", "六七八九十" ], lines[8, 2]
    assert_equal [ "一二三四五", "六七八九十" ], lines[13, 2]
    assert_equal 2, lines.count("一二三四五")
  end

  def test_width_one_preserves_each_oversized_body_grapheme
    lines = rendered_lines(state: info_state(original_text: "界", stage_extra: "語"), cols: 1, height: 14)

    assert_equal "界", lines[8]
    assert_equal "語", lines[12]
    assert_equal 1, lines.join.count("界")
    assert_equal 1, lines.join.count("語")
    refute_includes lines, "…"
  end

  def test_adapts_all_line_separators_and_preserves_blank_rows
    [ "a\rb\n", "a\r\nb\r\n", "a\nb\n" ].each do |source|
      lines = rendered_lines(state: info_state(original_text: source, stage_extra: source), height: 16)
      assert_equal [ "a", "b" ], lines[8, 2]
      assert_equal [ "a", "b" ], lines[13, 2]
    end
    assert_equal [ "", "a", "", "b" ],
      Hive::Tui::Views::IdeaPreview.wrapped_body("\na\n\nb\n", 10)
    assert_equal [ "", "" ], Hive::Tui::Views::IdeaPreview.wrapped_body("\n\n", 10)
    assert_empty Hive::Tui::Views::IdeaPreview.wrapped_body("", 10)
  end

  def test_mixed_graphemes_repack_from_source_at_each_width
    source = "ae\u0301界👩‍💻z"
    state = info_state(original_text: source)
    assert_equal [ "ae\u0301", "界", "👩‍💻", "z" ], rendered_lines(state: state, cols: 2, height: 13)[8, 4]
    assert_equal [ "ae\u0301界", "👩‍💻", "z" ], rendered_lines(state: state, cols: 4, height: 12)[8, 3]
    assert_equal source, state.original_text
  end

  def test_body_rows_preserve_ansi_bytes_without_synthesizing_resets
    source = "\e[7m界語\e[0mx\e"
    assert_equal [ "\e[7m界", "語\e[0m", "x\e" ],
      Hive::Tui::Views::IdeaPreview.wrapped_body(source, 1)
    assert_equal [ "\e[7m界" ], Hive::Tui::Views::IdeaPreview.wrapped_body("\e[7m界", 1)
  end

  def test_overflowing_cjk_keeps_ordered_prefix_and_standalone_marker
    source = "一二三四五六七八九十" * 3
    lines = rendered_lines(state: info_state(original_text: source), cols: 10, height: 12)

    assert_equal [ "一二三四五", "六七八九十", Hive::Tui::Styles::HINT.render("…") ], lines[8, 3]
    assert_equal [ 10, 10, 1 ], lines[8, 3].map { |line| Hive::Tui::Views::Format.display_width(line) }
  end

  def test_vertical_marker_preserves_retained_oversized_row_and_signals_displaced_row
    state = info_state(original_text: "界語漢")
    assert_equal [ "界", "…" ], rendered_lines(state: state, cols: 1, height: 11)[8, 2]
    lines = rendered_lines(state: state, cols: 1, height: 10)
    assert_equal "…", lines[8]
    refute_match(/[界語漢]/, lines.join)
  end

  def test_ascii_overflow_reserves_standalone_markers_for_each_overflowing_block
    source = (1..7).map { |i| "line #{i}" }.join("\n")
    state = info_state(original_text: source, stage_extra: source)

    single = rendered_lines(state: state.with(stage_extra: nil), height: 13)
    assert_equal [ "line 1", "line 2", "line 3", "…" ], single[8, 4]

    concurrent = rendered_lines(state: state, height: 18)
    assert_equal [ "line 1", "line 2", "line 3", "line 4", "line 5", "…" ], concurrent[8, 6]
    assert_equal [ "", "brainstorm.md", "…" ], concurrent[14, 3]
    assert_equal 2, concurrent.count("…")
  end

  def test_fitting_block_has_no_marker_when_sibling_overflows
    source = (1..6).map { |i| "extra #{i}" }.join("\n")
    lines = rendered_lines(state: info_state(original_text: "fits", stage_extra: source), height: 14)
    assert_equal "fits", lines[8]
    assert_equal [ "", "brainstorm.md", "─" * 13, "…" ], lines[9, 4]
    assert_equal 1, lines.count("…")
  end

  def test_tiny_allocations_retain_inline_info_header_and_extra_blank_row_marker
    state = info_state(slug: "tiny", stage: "3-plan", original_text: "body", stage_extra: "extra")
    # The existing full-width header loses its final bracket for the inline ellipsis.
    header = "Info: tiny#{' ' * 55}[stage: 3-plan…"
    one = rendered_lines(state: state, cols: 80, height: 2)
    two = rendered_lines(state: state, cols: 80, height: 3)

    assert_equal [ header ], one.first(1)
    assert_equal [ header, "…" ], two.first(2)
  end

  def test_width_one_ascii_overflow_uses_standalone_marker
    assert_equal [ "I", "…", "p" ], rendered_lines(cols: 1, height: 3)
  end

  def test_fitting_ascii_preview_retains_existing_output
    state = info_state(slug: "ascii", stage: "1-inbox", created_at: nil,
      folder_path: nil, latest_log_path: nil, original_text: "short\nbody")
    assert_equal [
      "Info: ascii  [stage: 1-in…", "─" * 26,
      "created_at:  (unknown)", "folder:      (unknown)", "latest log:  (none)", "",
      "Original idea", "─" * 13, "short", "body", "press q / Esc / i to close"
    ], rendered_lines(state: state, cols: 26, height: 11)
  end

  def test_zero_content_capacity_replaces_hint_when_either_body_is_supplied
    [ [ "body", nil ], [ nil, "extra" ], [ "\n", "" ] ].each do |original, extra|
      state = info_state(original_text: original, stage_extra: extra)
      assert_equal [ "…" ], rendered_lines(state: state, height: 1)
    end
    state = info_state(original_text: nil, stage_extra: nil)
    assert_equal [ Hive::Tui::Views::IdeaPreview::DISMISS_HINT.rjust(80) ],
      rendered_lines(state: state, height: 1)
  end
end
