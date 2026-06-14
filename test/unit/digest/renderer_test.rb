require "test_helper"
require "hive/digest/renderer"

class HiveDigestRendererTest < Minitest::Test
  def test_renders_projects_and_categories_in_fixed_order
    grouped = {
      "alpha" => [
        categorized("fix", "Fixes a crash.", display_name: "fix(api): Repair crash", pr_number: 20),
        categorized("feature", "Adds the digest.", display_name: "feat: Add digest", pr_number: 21),
        categorized("patrol", "Runs maintenance.", display_name: "patrol: Refresh docs", pr_number: 22)
      ],
      "beta" => [
        categorized("feature", "Adds beta support.", display_name: "Beta support", pr_number: 23)
      ]
    }

    message = Hive::Digest::Renderer.render(grouped)

    assert_match(/\A\*alpha\*/, message)
    assert message.index("_New features_") < message.index("_Fixes_")
    assert message.index("_Fixes_") < message.index("_Patrol tasks_")
    assert_includes message, "• Adds the digest\\. — [feat: Add digest](https://example.test/pulls/21)"
    assert_includes message, "• Fixes a crash\\. — [fix\\(api\\): Repair crash](https://example.test/pulls/20)"
    assert_includes message, "*beta*"
  end

  def test_omits_empty_categories_and_projects
    grouped = {
      "alpha" => [],
      "beta" => [ categorized("fix", "Fixes it.", pr_number: 24) ]
    }

    message = Hive::Digest::Renderer.render(grouped)

    refute_includes message, "*alpha*"
    refute_includes message, "_New features_"
    assert_includes message, "*beta*"
    assert_includes message, "_Fixes_"
  end

  def test_empty_input_renders_nothing_shipped_message
    assert_equal "Nothing shipped today 🌙", Hive::Digest::Renderer.render({})
    assert_equal "Nothing shipped today 🌙", Hive::Digest::Renderer.empty
  end

  def test_failed_notice_renders_date
    assert_equal "⚠️ Shipped digest for 2026\\-06\\-13 failed to generate\\.",
                 Hive::Digest::Renderer.failed(Date.new(2026, 6, 13))
  end

  def test_escape_mdv2_escapes_reserved_dynamic_text
    raw = "_*[]()~`>#+-=|{}.!"

    assert_equal "\\_\\*\\[\\]\\(\\)\\~\\`\\>\\#\\+\\-\\=\\|\\{\\}\\.\\!",
                 Hive::Digest::Renderer.escape_mdv2(raw)
  end

  def test_line_with_missing_url_keeps_display_name_without_link
    line = Hive::Digest::Renderer.render_line(
      categorized("feature", "Adds digest.", display_name: "Digest item", pr_url: "")
    )

    assert_equal "• Adds digest\\. — Digest item", line
  end

  private

  def categorized(category, summary, display_name: "Task", pr_number: 10, pr_url: nil)
    item = Hive::Digest::ShippedItem.new(
      project_name: "alpha",
      slug: "slug-#{pr_number}",
      display_name: display_name,
      pr_url: pr_url.nil? ? "https://example.test/pulls/#{pr_number}" : pr_url,
      pr_number: pr_number,
      pr_title: display_name,
      pr_body: "body",
      shipped_at: Time.utc(2026, 6, 13, 12)
    )
    Hive::Digest::CategorizedItem.new(item: item, category: category, summary: summary)
  end
end
