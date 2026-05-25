require "test_helper"
require "hive/tui/model"
require "hive/tui/views/token_stats"

class HiveTuiViewsTokenStatsTest < Minitest::Test
  def aggregate
    data = Hive::UsageDb.zero_aggregate
    data[:agents][:claude][:today] = { input: 1_500, output: 1_234_000, cached: 400_000 }
    data[:total][:today] = { input: 1_500, output: 1_234_000, cached: 400_000 }
    data
  end

  def test_renders_matrix_with_scope_label_and_formatted_usage
    state = Hive::Tui::Model::TokenStatsState.new(
      scope_level: :task,
      project_slug: "alpha",
      task_slug: "task-one"
    )
    model = Hive::Tui::Model.initial(cols: 120, rows: 30).with(token_stats_state: state)

    out = Hive::Tui::Views::TokenStats.render(model, aggregate: aggregate)

    assert_includes out, "Token usage"
    assert_includes out, "scope: alpha / task-one"
    assert_includes out, "agent"
    assert_includes out, "claude"
    assert_includes out, "1.5k/1.2M/400k"
    assert_includes out, "TOTAL"
    assert_includes out, "drill"
  end

  def test_renders_zeroes_for_empty_project_scope
    state = Hive::Tui::Model::TokenStatsState.new(
      scope_level: :project,
      project_slug: "empty"
    )
    model = Hive::Tui::Model.initial(cols: 100, rows: 24).with(token_stats_state: state)

    out = Hive::Tui::Views::TokenStats.render(model, aggregate: Hive::UsageDb.zero_aggregate)

    assert_includes out, "scope: empty"
    assert_includes out, "0/0/0"
  end
  def test_column_widths_shrink_usage_columns_for_narrow_inner_width
    rows = [
      Hive::Tui::Views::TokenStats::HEADER,
      [ "claude", "123456789", "123456789", "123456789", "123456789" ]
    ]

    widths = Hive::Tui::Views::TokenStats.column_widths(rows, 24)

    assert_equal 6, widths.first
    assert_operator widths[1], :<, 9
    assert_operator widths[1..].min, :>=, 6
  end
end
