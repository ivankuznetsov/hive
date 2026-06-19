require "test_helper"
require "hive/digest/renderer"
require "hive/digest/shipped_item"
require "hive/digest/categorizer"
require "hive/digest/stats"

class HiveDigestRendererTest < Minitest::Test
  DATE = Date.new(2026, 6, 19)

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

    message = Hive::Digest::Renderer.render(grouped, date: DATE, summary: "A busy day.")

    # The brand header leads, then the per-project sections (capitalized).
    assert_match(/\A\*Hive\* \\#Digest\n/, message)
    assert message.index("*Alpha*") < message.index("*Beta*")
    assert message.index("_Features_") < message.index("_Fixes_")
    assert message.index("_Fixes_") < message.index("_Patrol_")
    assert_includes message, "• Adds the digest\\. — [feat: Add digest](https://example.test/pulls/21)"
    assert_includes message, "• Fixes a crash\\. — [fix\\(api\\): Repair crash](https://example.test/pulls/20)"
    assert_includes message, "*Beta*"
  end

  def test_omits_empty_categories_and_projects
    grouped = {
      "alpha" => [],
      "beta" => [ categorized("fix", "Fixes it.", pr_number: 24) ]
    }

    message = Hive::Digest::Renderer.render(grouped, date: DATE)

    refute_includes message, "*Alpha*"
    refute_includes message, "_Features_"
    assert_includes message, "*Beta*"
    assert_includes message, "_Fixes_"
  end

  def test_header_carries_brand_hashtag_and_human_date
    message = Hive::Digest::Renderer.render(
      { "alpha" => [ categorized("fix", "Fixes it.", pr_number: 24) ] }, date: DATE
    )

    # "*Hive* \#Digest" then a human date — the hashtag's # is MarkdownV2-escaped
    # but left outside the bold span so Telegram still tags it.
    assert_match(/\A\*Hive\* \\#Digest\nFri, 19 June 2026/, message)
  end

  def test_summary_block_rendered_when_present_and_omitted_when_blank
    grouped = { "alpha" => [ categorized("fix", "Fixes it.", pr_number: 24) ] }

    with_summary = Hive::Digest::Renderer.render(grouped, date: DATE, summary: "A calm day.")
    assert_includes with_summary, "_Summary_\nA calm day\\."

    without_summary = Hive::Digest::Renderer.render(grouped, date: DATE, summary: "  ")
    refute_includes without_summary, "_Summary_"
  end

  def test_footer_shows_lines_prs_and_commits_when_measured
    totals = Hive::Digest::Totals.new(prs: 5, commits: 22, additions: 2111, deletions: 1102, measured_prs: 5)

    message = Hive::Digest::Renderer.render(
      { "alpha" => [ categorized("fix", "Fixes it.", pr_number: 24) ] }, date: DATE, totals: totals
    )

    assert_includes message, "Lines \\+2111/\\-1102 · PRs 5 · Commits 22"
  end

  def test_footer_omits_lines_and_commits_when_nothing_measured
    # gh was unavailable: no PR stats fetched. Show only the PR count rather
    # than a misleading "Lines +0/-0".
    totals = Hive::Digest::Totals.new(prs: 3, commits: 0, additions: 0, deletions: 0, measured_prs: 0)

    message = Hive::Digest::Renderer.render(
      { "alpha" => [ categorized("fix", "Fixes it.", pr_number: 24) ] }, date: DATE, totals: totals
    )

    assert_includes message, "PRs 3"
    refute_includes message, "Lines "
    refute_includes message, "Commits "
  end

  def test_empty_input_renders_nothing_shipped_message
    assert_equal "Nothing shipped today 🌙", Hive::Digest::Renderer.render({}, date: DATE)
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

  def test_render_line_escapes_link_breaking_chars_in_url
    line = Hive::Digest::Renderer.render_line(
      categorized("feature", "Adds digest.", display_name: "Digest item",
                  pr_url: "https://example.test/foo(bar)\\baz")
    )

    # Inside the link destination, ')' and '\' must be escaped; '(' is left
    # alone. One un-escaped ')' would otherwise close the link early and
    # fail the whole day's MarkdownV2 send.
    assert_includes line, "bar\\)"
    assert_includes line, "\\\\baz"
  end

  def test_category_order_matches_shared_constant
    assert_equal Hive::Digest::Categories::ORDERED, Hive::Digest::Renderer::CATEGORY_ORDER
    assert_equal Hive::Digest::Categories::VALID,
                 Hive::Digest::Renderer::CATEGORY_ORDER.map(&:first)
  end

  def test_truncate_summary_is_a_noop_within_the_cap
    text = "a" * Hive::Digest::Renderer::MAX_SUMMARY_LENGTH

    assert_equal text, Hive::Digest::Renderer.truncate_summary(text)
  end

  def test_truncate_summary_caps_an_overlong_summary_with_an_ellipsis
    over = "b" * (Hive::Digest::Renderer::MAX_SUMMARY_LENGTH + 50)

    truncated = Hive::Digest::Renderer.truncate_summary(over)

    assert_equal Hive::Digest::Renderer::MAX_SUMMARY_LENGTH, truncated.length,
                 "an overlong model summary must be capped so the escaped line stays under the chunk boundary"
    assert truncated.end_with?("…"), "the cap must mark the truncation with an ellipsis"
  end

  def test_truncate_overall_summary_caps_an_overlong_summary_with_an_ellipsis
    # The model's overall summary is untrusted, length-unbounded text; it must be
    # bounded before escaping (its own constant, independent of the per-item cap)
    # so the rendered Summary block can't approach Telegram's 4096 chunk limit.
    over = "y" * (Hive::Digest::Renderer::MAX_OVERALL_SUMMARY_LENGTH + 50)

    truncated = Hive::Digest::Renderer.truncate_overall_summary(over)

    assert_equal Hive::Digest::Renderer::MAX_OVERALL_SUMMARY_LENGTH, truncated.length,
                 "an overlong overall summary must be capped"
    assert truncated.end_with?("…"), "the cap must mark the truncation with an ellipsis"
  end

  def test_truncate_label_caps_an_overlong_label_with_an_ellipsis
    over = "c" * (Hive::Digest::Renderer::MAX_LABEL_LENGTH + 50)

    truncated = Hive::Digest::Renderer.truncate_label(over)

    assert_equal Hive::Digest::Renderer::MAX_LABEL_LENGTH, truncated.length,
                 "an overlong display label must be capped so the escaped link line stays under the boundary"
    assert truncated.end_with?("…"), "the cap must mark the truncation with an ellipsis"
  end

  def test_render_line_bounds_an_overlong_label
    over = "d" * (Hive::Digest::Renderer::MAX_LABEL_LENGTH + 500)
    rendered = Hive::Digest::Renderer.render(
      { "alpha" => [ categorized("feature", "Adds digest.", display_name: over) ] }, date: DATE
    )

    # The label inside the link must be bounded (≤ cap, plus MarkdownV2 escapes
    # which at most double it) so the whole line can't approach 4096.
    label_in_link = rendered[/\[([^\]]*)\]/, 1]
    refute_nil label_in_link
    assert_operator label_in_link.length, :<=, Hive::Digest::Renderer::MAX_LABEL_LENGTH * 2,
                    "an overlong label must be truncated before escaping into the link"
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
