require "test_helper"
require "hive/tui/help"
require "hive/tui/model"
require "hive/tui/views/help_overlay"

class HiveTuiViewsHelpOverlayTest < Minitest::Test
  include HiveTestHelper

  def model(cols: 80, rows: 24)
    Hive::Tui::Model.initial.with(mode: :help, cols: cols, rows: rows)
  end

  def test_renders_title_and_dismiss_hint
    out = Hive::Tui::Views::HelpOverlay.render(model)
    assert_includes out, "hive tui — keybindings"
    assert_includes out, "press any key to dismiss"
  end

  def test_renders_every_mode_header_with_bindings
    out = Hive::Tui::Views::HelpOverlay.render(model)
    assert_includes out, "Grid mode"
    assert_includes out, "Triage mode"
    assert_includes out, "Log tail mode"
    assert_includes out, "Filter prompt"
    assert_includes out, "New-idea prompt",
                    "v2 :new_idea bindings must surface in the help overlay; without this " \
                    "header, the n / Enter / Esc bindings in :new_idea mode are invisible"
  end

  def test_renders_v2_pane_focus_and_navigation_keys
    out = Hive::Tui::Views::HelpOverlay.render(model)
    assert_includes out, "Tab",        "Tab pane-focus binding must be discoverable"
    assert_includes out, "Shift+Tab",  "Shift+Tab pane-focus binding must be discoverable"
    assert_match(/\bn\b.*new-idea/i, out, "n binding must surface with its action description")
    assert_match(/\bg\b.*top/i, out, "g (jump to top) must be discoverable")
    assert_match(/\bG\b.*bottom/i, out, "G (jump to bottom) must be discoverable")
  end

  def test_includes_grid_workflow_verb_keys
    out = Hive::Tui::Views::HelpOverlay.render(model)
    %w[brainstorm plan develop review pr archive].each do |verb|
      assert_match(/#{verb}/, out, "help overlay must list #{verb}")
    end
  end

  def test_includes_triage_rebindings
    out = Hive::Tui::Views::HelpOverlay.render(model)
    assert_includes out, "toggle accept/reject"
    assert_includes out, "bulk accept"
    assert_includes out, "bulk reject"
  end

  def test_build_lines_groups_bindings_by_mode
    lines = Hive::Tui::Views::HelpOverlay.build_lines
    grid_idx = lines.index { |l| l.include?("Grid mode") }
    triage_idx = lines.index { |l| l.include?("Triage mode") }
    refute_nil grid_idx
    refute_nil triage_idx
    assert grid_idx < triage_idx, "Grid section must precede Triage section"
  end

  def test_renders_inside_a_bordered_box
    out = Hive::Tui::Views::HelpOverlay.render(model)
    # Lipgloss NORMAL border uses "─│┌┐└┘" so at least one corner char
    # should appear in the rendered output.
    assert_match(/[┌┐└┘─│]/, out, "rendered overlay must include border characters")
  end
end
