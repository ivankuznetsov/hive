require "test_helper"
require "hive/tui/views/format"

# Direct unit coverage for Hive::Tui::Views::Format cell helpers. The
# grapheme-boundary and padding-clamp edges are otherwise only exercised
# indirectly via the happy-path alignment tests in tasks_pane_test.rb.
class HiveTuiViewsFormatTest < Minitest::Test
  F = Hive::Tui::Views::Format

  def test_display_width_counts_wide_clusters_as_two_cells
    assert_equal 2, F.display_width("🤖")
    assert_equal 1, F.display_width("a")
    assert_equal 0, F.display_width(nil)
  end

  def test_take_cells_never_breaks_inside_a_wide_cluster
    # max_width 1 cannot fit the 2-cell emoji, so it must drop it whole
    # rather than emit half a grapheme cluster.
    assert_equal "", F.take_cells("🤖x", 1)
    assert_equal "🤖", F.take_cells("🤖x", 2)
    assert_equal "🤖x", F.take_cells("🤖x", 3)
  end

  def test_truncate_appends_ellipsis_when_over_width
    assert_equal "ab…", F.truncate("abcdef", 3)
  end

  def test_truncate_hard_cuts_without_ellipsis_when_width_below_two
    # max_width < 2 leaves no room for the ellipsis suffix.
    assert_equal "a", F.truncate("abc", 1)
    assert_equal "", F.truncate("🤖", 1)
  end

  def test_truncate_returns_empty_for_nonpositive_width
    assert_equal "", F.truncate("abc", 0)
    assert_equal "", F.truncate("abc", -3)
  end

  def test_ljust_cells_pads_to_display_width
    assert_equal "ab   ", F.ljust_cells("ab", 5)
  end

  def test_rjust_cells_pads_to_display_width
    assert_equal "   ab", F.rjust_cells("ab", 5)
  end

  def test_ljust_cells_clamps_when_label_exceeds_width
    # Over-width input is truncated, never negative-padded.
    result = F.ljust_cells("abcdef", 4)
    assert_equal 4, F.display_width(result)
    assert_equal "abc…", result
  end

  def test_justify_helpers_account_for_wide_clusters_when_padding
    # One 2-cell emoji in a width-4 field leaves exactly 2 pad cells.
    assert_equal "🤖  ", F.ljust_cells("🤖", 4)
    assert_equal "  🤖", F.rjust_cells("🤖", 4)
  end
end
