require "test_helper"
require "hive/findings"
require "hive/tui/triage_state"

# TriageState owns the per-session cursor and command-builder for the
# findings triage mode. These tests pin the argv tuples the render loop
# hands to Subprocess (toggle / develop / bulk), the cursor clamp at
# both ends, the empty-list contract (`current_finding` is nil and
# `toggle_command(nil)` raises), and the three relocate-cursor outcomes
# the plan calls out for concurrent-rewrite safety.
class TuiTriageStateTest < Minitest::Test
  include HiveTestHelper

  def make_finding(id:, severity: "high", accepted: false, title: "Auth check missing", justification: "user can bypass", line_index: 0)
    Hive::Findings::Finding.new(
      id: id,
      severity: severity,
      accepted: accepted,
      title: title,
      justification: justification,
      line_index: line_index
    )
  end

  # -------- toggle_command -----------------------------------------

  def test_toggle_command_for_accepted_finding_returns_reject_argv
    f = make_finding(id: 3, accepted: true)
    state = Hive::Tui::TriageState.new(slug: "fix-auth", findings: [ f ])
    assert_equal [ "hive", "reject-finding", "fix-auth", "3" ], state.toggle_command(f)
  end

  def test_toggle_command_for_unaccepted_finding_returns_accept_argv
    f = make_finding(id: 7, accepted: false)
    state = Hive::Tui::TriageState.new(slug: "fix-auth", findings: [ f ])
    assert_equal [ "hive", "accept-finding", "fix-auth", "7" ], state.toggle_command(f)
  end

  def test_toggle_command_with_nil_finding_raises_argument_error
    state = Hive::Tui::TriageState.new(slug: "fix-auth", findings: [])
    assert_raises(ArgumentError) { state.toggle_command(nil) }
  end

  # -------- develop_command ----------------------------------------

  def test_develop_command_returns_hive_develop_with_from_4_execute
    state = Hive::Tui::TriageState.new(slug: "fix-auth", findings: [])
    assert_equal [ "hive", "develop", "fix-auth", "--from", "4-execute" ], state.develop_command
  end

  # -------- bulk_command -------------------------------------------

  def test_bulk_command_accept_returns_accept_finding_all_argv
    state = Hive::Tui::TriageState.new(slug: "fix-auth", findings: [])
    assert_equal [ "hive", "accept-finding", "fix-auth", "--all" ], state.bulk_command(:accept)
  end

  def test_bulk_command_reject_returns_reject_finding_all_argv
    state = Hive::Tui::TriageState.new(slug: "fix-auth", findings: [])
    assert_equal [ "hive", "reject-finding", "fix-auth", "--all" ], state.bulk_command(:reject)
  end

  def test_bulk_command_with_unknown_direction_raises_argument_error
    state = Hive::Tui::TriageState.new(slug: "fix-auth", findings: [])
    assert_raises(ArgumentError) { state.bulk_command(:nope) }
  end

  # -------- cursor clamp -------------------------------------------

  def test_cursor_starts_at_zero
    findings = [ make_finding(id: 1), make_finding(id: 2) ]
    state = Hive::Tui::TriageState.new(slug: "x", findings: findings)
    assert_equal 0, state.cursor
  end

  def test_cursor_down_clamps_at_last_index
    findings = [ make_finding(id: 1), make_finding(id: 2), make_finding(id: 3) ]
    state = Hive::Tui::TriageState.new(slug: "x", findings: findings)
    10.times { state.cursor_down }
    assert_equal 2, state.cursor
  end

  def test_cursor_up_clamps_at_zero
    findings = [ make_finding(id: 1), make_finding(id: 2) ]
    state = Hive::Tui::TriageState.new(slug: "x", findings: findings)
    10.times { state.cursor_up }
    assert_equal 0, state.cursor
  end

  # -------- empty findings -----------------------------------------

  def test_current_finding_is_nil_when_findings_empty
    state = Hive::Tui::TriageState.new(slug: "x", findings: [])
    assert_nil state.current_finding
  end

  def test_cursor_down_is_noop_when_findings_empty
    state = Hive::Tui::TriageState.new(slug: "x", findings: [])
    state.cursor_down
    assert_equal 0, state.cursor
  end

  # -------- relocate_cursor ----------------------------------------

  def test_relocate_cursor_finds_prior_finding_at_new_index_and_returns_relocated
    f1 = make_finding(id: 1, severity: "medium", title: "Other issue")
    f2 = make_finding(id: 2, severity: "high",   title: "Auth check missing")
    state = Hive::Tui::TriageState.new(slug: "x", findings: [ f1, f2 ])
    state.cursor_down # cursor on f2

    # Reload: f2's content reordered to index 0; ID may have changed.
    f2_reloaded = make_finding(id: 5, severity: "high", title: "Auth check missing")
    f1_reloaded = make_finding(id: 6, severity: "medium", title: "Other issue")

    indicator = state.relocate_cursor([ f2_reloaded, f1_reloaded ])
    assert_equal :relocated, indicator
    assert_equal 0, state.cursor
    assert_equal "Auth check missing", state.current_finding.title
  end

  def test_relocate_cursor_resets_to_zero_and_returns_reset_when_prior_finding_missing
    f1 = make_finding(id: 1, severity: "high", title: "Auth check missing")
    f2 = make_finding(id: 2, severity: "low", title: "Trailing whitespace")
    state = Hive::Tui::TriageState.new(slug: "x", findings: [ f1, f2 ])
    state.cursor_down # cursor on f2 (Trailing whitespace)

    # Reload: the prior cursor finding is gone (deleted by reviewer).
    f1_reloaded = make_finding(id: 1, severity: "high", title: "Auth check missing")

    indicator = state.relocate_cursor([ f1_reloaded ])
    assert_equal :reset, indicator
    assert_equal 0, state.cursor
  end

  def test_relocate_cursor_returns_unchanged_when_finding_at_same_index_with_same_content
    f1 = make_finding(id: 1, severity: "high", title: "Auth check missing")
    f2 = make_finding(id: 2, severity: "low", title: "Trailing whitespace")
    state = Hive::Tui::TriageState.new(slug: "x", findings: [ f1, f2 ])
    state.cursor_down # cursor on f2

    # Reload: same findings, same order, same content.
    indicator = state.relocate_cursor([ f1, f2 ])
    assert_equal :unchanged, indicator
    assert_equal 1, state.cursor
  end

  def test_relocate_cursor_with_empty_prior_findings_resets
    state = Hive::Tui::TriageState.new(slug: "x", findings: [])
    f1 = make_finding(id: 1)
    indicator = state.relocate_cursor([ f1 ])
    assert_equal :reset, indicator
    assert_equal 0, state.cursor
  end
end
