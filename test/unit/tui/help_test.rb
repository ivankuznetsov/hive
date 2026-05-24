require "test_helper"
require "hive/tui/help"
require "hive/workflows"

# `Hive::Tui::Help::BINDINGS` is the single source of truth for the
# `?` overlay's keybinding cheatsheet. These tests pin the structural
# invariants and the cross-check that a verb rename in
# `Hive::Workflows::VERBS` breaks the test rather than silently
# leaving the help text stale.
class TuiHelpTest < Minitest::Test
  include HiveTestHelper

  def test_every_workflow_verb_action_resolves_in_workflows_verbs
    workflow_verb_actions = Hive::Tui::Help::BINDINGS.select do |entry|
      entry[:action].is_a?(Symbol) && Hive::Workflows::VERBS.key?(entry[:action].to_s)
    end

    refute_empty workflow_verb_actions,
                 "BINDINGS must include at least one workflow-verb action " \
                 "(otherwise the cross-check is a no-op)"

    workflow_verb_actions.each do |entry|
      assert Hive::Workflows::VERBS.key?(entry[:action].to_s),
             "verb action #{entry[:action].inspect} (key=#{entry[:key]}) " \
             "must resolve via Hive::Workflows::VERBS"
    end
  end

  def test_every_workflow_verb_appears_in_grid_mode_bindings
    grid_verb_actions = Hive::Tui::Help::BINDINGS
                          .select { |b| b[:mode] == :grid && b[:action].is_a?(Symbol) }
                          .map { |b| b[:action].to_s }
                          .select { |a| Hive::Workflows::VERBS.key?(a) }

    expected = Hive::Workflows::VERBS.keys.sort
    assert_equal expected, grid_verb_actions.sort,
                 "every workflow verb must have exactly one grid-mode binding " \
                 "(if you renamed a verb, update BINDINGS)"
  end

  def test_grid_mode_keys_are_unique
    grid_keys = Hive::Tui::Help::BINDINGS.select { |b| b[:mode] == :grid }.map { |b| b[:key] }
    assert_equal grid_keys.uniq.size, grid_keys.size,
                 "grid-mode key column must have no duplicates: #{grid_keys.tally.select { |_, c| c > 1 }.inspect}"
  end

  def test_each_entry_has_required_fields
    Hive::Tui::Help::BINDINGS.each do |entry|
      assert entry[:mode], "entry missing :mode field: #{entry.inspect}"
      assert entry[:key], "entry missing :key field: #{entry.inspect}"
      assert entry[:action], "entry missing :action field: #{entry.inspect}"
      assert entry[:description], "entry missing :description field: #{entry.inspect}"
      assert entry[:description].is_a?(String) && !entry[:description].empty?,
             ":description must be a non-empty String for #{entry[:key]}"
    end
  end

  def test_modes_are_drawn_from_a_known_set
    expected_modes = %i[grid triage log_tail red_status_detail filter idea_preview new_idea_project new_idea].to_set
    actual_modes = Hive::Tui::Help::BINDINGS.map { |b| b[:mode] }.to_set
    extra = actual_modes - expected_modes
    assert_empty extra, "unexpected modes in BINDINGS: #{extra.inspect}"
  end

  def test_lowercase_o_opens_task_folder_in_grid_mode
    # The `o` binding is the read-only browse gesture distinct from
    # Enter (workflow-contextual) and the verb keys (subprocess
    # dispatch). Assert on intent words rather than literal copy so a
    # future polish pass on the description doesn't break the test.
    entry = Hive::Tui::Help::BINDINGS.find { |b| b[:mode] == :grid && b[:key] == "o" }
    refute_nil entry, "expected a grid-mode binding for `o`"
    assert_equal :open_task_folder, entry[:action]
    assert_match(/browse/i, entry[:description])
    assert_match(/\$EDITOR|editor/i, entry[:description])
  end

  def test_lowercase_s_opens_task_in_agent_in_grid_mode
    entry = Hive::Tui::Help::BINDINGS.find { |b| b[:mode] == :grid && b[:key] == "s" }
    refute_nil entry, "expected a grid-mode binding for `s`"
    assert_equal :open_in_agent, entry[:action]
    assert_match(/agent/i, entry[:description])
    assert_match(/MANUAL_STEERING/, entry[:description])
  end

  def test_red_status_detail_mode_pins_two_action_contract
    # Pin the operator-visible contract for red_status_detail mode:
    # exactly Enter / o / q / Esc — and the removed [f] / [R] bindings
    # must NOT come back without an explicit help-overlay update.
    entries = Hive::Tui::Help::BINDINGS.select { |b| b[:mode] == :red_status_detail }
    keys = entries.map { |b| b[:key] }

    assert_equal %w[Enter o q Esc].sort, keys.sort,
                 "red_status_detail mode must expose exactly Enter / o / q / Esc"

    enter = entries.find { |b| b[:key] == "Enter" }
    assert_equal :recover, enter[:action]
    o_key = entries.find { |b| b[:key] == "o" }
    assert_equal :open_in_agent, o_key[:action]
    %w[Esc q].each do |k|
      back = entries.find { |b| b[:key] == k }
      assert_equal :back, back[:action], "#{k} in red_status_detail must close the screen"
    end

    refute_includes keys, "f", "removed [f] manual-fix binding must not return"
    refute_includes keys, "R", "removed [R] refresh-diagnosis binding must not return"
  end

  def test_capital_p_is_open_pr_lowercase_p_is_plan
    grid = Hive::Tui::Help::BINDINGS.select { |b| b[:mode] == :grid }
    by_key = grid.each_with_object({}) { |b, h| h[b[:key]] = b[:action] }
    assert_equal :"open-pr", by_key["P"], "capital P must be open-pr (so it doesn't collide with plan)"
    assert_equal :finalize,  by_key["F"], "capital F must be finalize"
    assert_equal :plan,      by_key["p"], "lowercase p must be plan"
  end

  def test_bindings_is_frozen
    assert Hive::Tui::Help::BINDINGS.frozen?,
           "BINDINGS must be frozen so callers can't mutate the help text at runtime"
  end

  def test_bindings_inner_hashes_are_frozen
    Hive::Tui::Help::BINDINGS.each do |entry|
      assert entry.frozen?, "BINDINGS entry must be frozen: #{entry.inspect}"
    end
  end

  # Reverse direction of `test_every_workflow_verb_appears_in_grid_mode_bindings`:
  # cross-check that no grid-mode binding references an action that
  # neither resolves to a workflow verb nor matches the curated list of
  # known TUI-internal actions. A typo in BINDINGS or a renamed verb
  # would otherwise leave the cheatsheet pointing at vapor.
  def test_no_grid_mode_binding_references_a_nonexistent_verb
    known_non_verb_actions = %i[
      cursor_down cursor_up cursor_jump_top cursor_jump_bottom
      open_contextual open_task_folder open_idea_preview open_in_agent
      filter project_scope help quit
      pane_focus_toggle pane_focus_left pane_focus_right new_idea
      drop_task
    ]
    Hive::Tui::Help::BINDINGS.select { |b| b[:mode] == :grid && b[:action].is_a?(Symbol) }.each do |entry|
      action = entry[:action]
      next unless action.to_s.match?(/\A[a-z_]+\z/) # skip non-verb actions

      if Hive::Workflows::VERBS.key?(action.to_s)
        pass
      elsif known_non_verb_actions.include?(action)
        pass
      else
        flunk "BINDINGS references unknown action: #{action.inspect} (key=#{entry[:key]})"
      end
    end
  end

  def test_binding_for_i_exists_in_grid_mode
    entry = Hive::Tui::Help::BINDINGS.find { |b| b[:mode] == :grid && b[:key] == "i" }

    refute_nil entry, "expected a grid-mode binding for `i`"
    assert_equal :open_idea_preview, entry[:action]
    assert_match(/original idea/i, entry[:description])
  end

  def test_binding_for_capital_x_documents_task_drop
    entry = Hive::Tui::Help::BINDINGS.find { |b| b[:mode] == :grid && b[:key] == "X" }

    refute_nil entry, "expected a grid-mode binding for `X`"
    assert_equal :drop_task, entry[:action]
    assert_match(/focused task/i, entry[:description])
    assert_match(/no undo/i, entry[:description])
  end

  def test_idea_preview_mode_has_a_dismiss_entry
    entry = Hive::Tui::Help::BINDINGS.find { |b| b[:mode] == :idea_preview && b[:key] == "any" }

    refute_nil entry, "expected an idea-preview dismissal binding"
    assert_equal :back, entry[:action]
    assert_match(/dismiss/i, entry[:description])
  end
end
