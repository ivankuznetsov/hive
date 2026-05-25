require "test_helper"
require "hive/tui/views/usage_footer"

class HiveTuiViewsUsageFooterTest < Minitest::Test
  def aggregate(total)
    {
      agents: {},
      total: {
        today: total,
        "7d": total,
        "30d": total,
        all: total
      }
    }
  end

  def test_empty_aggregate_renders_all_zero_buckets
    out = Hive::Tui::Views::UsageFooter.render(
      aggregate: aggregate({ input: 0, output: 0, cached: 0 }),
      width: 120
    )

    assert_equal "today 0/0/0 • 7d 0/0/0 • all 0/0/0 • tokens", out
    refute_includes out, "30d"
  end

  def test_formats_k_and_m_units
    text = Hive::Tui::Views::UsageFooter.text(
      aggregate({ input: 1_500, output: 1_234_000, cached: 400_000 })
    )

    assert_includes text, "1.5k/1.2M/400k"
  end

  def test_render_truncates_to_width
    out = Hive::Tui::Views::UsageFooter.render(
      aggregate: aggregate({ input: 1_500, output: 1_234_000, cached: 400_000 }),
      width: 30
    )

    assert_operator out.length, :<=, 30
    assert_match(/\Atoday /, out)
  end
end
