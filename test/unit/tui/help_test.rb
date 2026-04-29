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

  def test_triage_mode_keys_are_unique
    triage_keys = Hive::Tui::Help::BINDINGS.select { |b| b[:mode] == :triage }.map { |b| b[:key] }
    assert_equal triage_keys.uniq.size, triage_keys.size,
                 "triage-mode key column must have no duplicates"
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
    expected_modes = %i[grid triage log_tail filter].to_set
    actual_modes = Hive::Tui::Help::BINDINGS.map { |b| b[:mode] }.to_set
    extra = actual_modes - expected_modes
    assert_empty extra, "unexpected modes in BINDINGS: #{extra.inspect}"
  end

  def test_capital_p_is_pr_lowercase_p_is_plan
    grid = Hive::Tui::Help::BINDINGS.select { |b| b[:mode] == :grid }
    by_key = grid.each_with_object({}) { |b, h| h[b[:key]] = b[:action] }
    assert_equal :pr,    by_key["P"], "capital P must be pr (so it doesn't collide with plan)"
    assert_equal :plan,  by_key["p"], "lowercase p must be plan"
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
    known_non_verb_actions = %i[cursor_down cursor_up open_contextual filter project_scope help quit]
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
end
