require "test_helper"
require "hive/commands/status"
require "hive/status_projection"

class StatusProjectionTest < Minitest::Test
  def test_action_label_order_is_frozen_and_terminates_with_error
    order = Hive::StatusProjection::ACTION_LABEL_ORDER

    refute_empty order
    assert order.frozen?
    assert_equal "Error", order.last
  end

  def test_label_position_ranks_known_labels_by_order_and_unknown_last
    order = Hive::StatusProjection::ACTION_LABEL_ORDER

    assert_equal 0, Hive::StatusProjection.label_position(order.first)
    assert_operator(
      Hive::StatusProjection.label_position("Ready to brainstorm"), :<,
      Hive::StatusProjection.label_position("Agent running")
    )
    assert_equal order.length,
                 Hive::StatusProjection.label_position("Totally unknown label")
  end

  # The command boundary re-exports the projection-owned constant so label
  # grouping and the TUI can never drift onto two different orders.
  def test_commands_status_reexports_the_projection_owned_order
    assert_same(
      Hive::StatusProjection::ACTION_LABEL_ORDER,
      Hive::Commands::Status::ACTION_LABEL_ORDER
    )
  end
end
