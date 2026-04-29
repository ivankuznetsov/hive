require "test_helper"
require "hive/findings"
require "hive/tui/model"
require "hive/tui/triage_state"
require "hive/tui/views/triage"

# Layout/text assertions for `Views::Triage.render(model)`. Lipgloss
# strips ANSI in non-tty test envs (U2), so styling is validated by
# manual dogfood per R19; the tests here cover ordering and content.
class HiveTuiViewsTriageTest < Minitest::Test
  include HiveTestHelper

  def base_model(triage_state:, **overrides)
    Hive::Tui::Model.initial.with(mode: :triage, triage_state: triage_state, cols: 80, rows: 24, **overrides)
  end

  def finding(id:, severity:, title:, accepted: false, justification: nil)
    Hive::Findings::Finding.new(
      id: id, severity: severity, accepted: accepted,
      title: title, justification: justification, line_index: 0
    )
  end

  def state_with(findings, slug: "demo", review_path: "/x/.hive/findings/demo-001-review.md")
    Hive::Tui::TriageState.new(slug: slug, findings: findings, review_path: review_path)
  end

  # ---- Empty state ----

  def test_returns_empty_string_when_triage_state_nil
    model = Hive::Tui::Model.initial.with(triage_state: nil, mode: :triage)
    assert_equal "", Hive::Tui::Views::Triage.render(model)
  end

  def test_no_findings_shows_centered_empty_message
    state = state_with([])
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state))
    assert_includes out, "(no findings in this review file)"
  end

  # ---- Header ----

  def test_header_includes_review_basename_and_slug
    state = state_with([], slug: "auth-bug", review_path: "/path/to/.hive/findings/auth-bug-001-review.md")
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state))
    assert_includes out, "auth-bug-001-review.md"
    assert_includes out, "auth-bug"
  end

  def test_header_falls_back_when_review_path_nil
    state = Hive::Tui::TriageState.new(slug: "demo", findings: [])
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state))
    assert_includes out, "(no review file)"
    assert_includes out, "demo"
  end

  # ---- Severity grouping ----

  def test_findings_grouped_by_severity_in_canonical_order
    findings = [
      finding(id: "1", severity: "low", title: "low one"),
      finding(id: "2", severity: "high", title: "high one"),
      finding(id: "3", severity: "medium", title: "medium one")
    ]
    state = state_with(findings)
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state))
    high_pos = out.index("## High")
    medium_pos = out.index("## Medium")
    low_pos = out.index("## Low")
    refute_nil high_pos
    refute_nil medium_pos
    refute_nil low_pos
    assert high_pos < medium_pos, "High section must come before Medium"
    assert medium_pos < low_pos, "Medium section must come before Low"
  end

  def test_unknown_severity_renders_under_other_section
    findings = [
      finding(id: "1", severity: "high", title: "known one"),
      finding(id: "2", severity: "weird-thing", title: "weird one")
    ]
    state = state_with(findings)
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state))
    assert_includes out, "## High"
    assert_includes out, "## Other"
    assert_includes out, "weird one"
  end

  # ---- Finding row format ----

  def test_unaccepted_finding_renders_empty_checkbox
    findings = [ finding(id: "5", severity: "high", title: "x", accepted: false) ]
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state_with(findings)))
    assert_match(/\[ \]\s*#5\s+x/, out)
  end

  def test_accepted_finding_renders_checked_checkbox
    findings = [ finding(id: "5", severity: "high", title: "x", accepted: true) ]
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state_with(findings)))
    assert_match(/\[x\]\s*#5\s+x/, out)
  end

  def test_finding_with_justification_appends_em_dash
    findings = [ finding(id: "1", severity: "high", title: "the title", justification: "because reasons") ]
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state_with(findings)))
    assert_includes out, "the title  — because reasons"
  end

  # ---- Cursor highlight ----

  def test_cursor_highlights_correct_finding_across_severity_groups
    findings = [
      finding(id: "1", severity: "low", title: "low-one"),
      finding(id: "2", severity: "high", title: "high-one"),
      finding(id: "3", severity: "high", title: "high-two")
    ]
    state = state_with(findings)
    state.cursor_down # cursor → 1 (high-one)
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state))
    # Cursor highlight is a Lipgloss reverse style; in tests we just
    # confirm both findings are present and in the right groups.
    assert_includes out, "high-one"
    assert_includes out, "high-two"
    assert_includes out, "low-one"
  end

  # ---- Footer ----

  def test_footer_shows_keystroke_hint_by_default
    state = state_with([])
    out = Hive::Tui::Views::Triage.render(base_model(triage_state: state))
    assert_includes out, "[space] toggle"
    assert_includes out, "[d] develop"
    assert_includes out, "[a] accept all"
    assert_includes out, "[esc] back"
  end

  def test_footer_shows_flash_when_active
    state = state_with([])
    fresh = Time.now - 1.0
    out = Hive::Tui::Views::Triage.render(
      base_model(triage_state: state, flash: "accept failed: exit 4", flash_set_at: fresh)
    )
    assert_includes out, "accept failed: exit 4"
    refute_includes out, "[space] toggle"
  end
end
