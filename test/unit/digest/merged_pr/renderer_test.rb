require "test_helper"
require "hive/digest/merged_pr/renderer"
require "hive/digest/stats"

class HiveDigestMergedPrRendererTest < Minitest::Test
  PR = Hive::Digest::MergedPr::PullRequest

  def test_renders_grouped_stats_footer_and_chronological_lines
    prs = [
      pr(repo: "b/repo", number: 3, merged_at: "2026-06-13T12:00:00Z"),
      pr(repo: "a/repo", number: 2, merged_at: "2026-06-13T11:00:00Z", author: "bob"),
      pr(repo: "a/repo", number: 1, merged_at: "2026-06-13T10:00:00Z", title: "Fix (docs)")
    ]

    text = Hive::Digest::MergedPr::Renderer.render(
      prs,
      date: Date.new(2026, 6, 13),
      totals: totals(prs: 3, measured_prs: 3, additions: 120, deletions: 30, commits: 6)
    )

    assert_includes text, "Merged PR digest — 2026\\-06\\-13"
    assert_includes text, Hive::Digest::Renderer::FOOTER_DIVIDER
    assert_includes text, "Lines \\+120/\\-30 · PRs 3 · Commits 6"
    refute_includes text, "Total:"
    assert_operator text.index("`a/repo — 2`"), :<, text.index("`b/repo — 1`")
    assert_operator text.index("\\#1 Fix \\(docs\\)"), :<, text.index("\\#2 Title")
    assert_operator text.index("`b/repo — 1`"), :<, text.index(Hive::Digest::Renderer::FOOTER_DIVIDER)
  end

  def test_hive_match_replaces_author_suffix
    text = Hive::Digest::MergedPr::Renderer.render(
      [ pr(hive_slug: "task-260613-abcd", hive_stage: "9-done") ],
      date: Date.new(2026, 6, 13),
      totals: totals
    )

    assert_includes text, "Hive task matched"
    refute_includes text, "alice"
  end

  def test_empty_day_renders_zero_count
    text = Hive::Digest::MergedPr::Renderer.render(
      [], date: Date.new(2026, 6, 13), totals: totals(prs: 0, measured_prs: 0)
    )

    assert_equal "Merged PR digest — 2026\\-06\\-13\n\n──────────\nPRs 0", text
  end

  def test_long_title_is_length_capped_before_escaping
    # Mirror the sibling renderer's cap so a Telegram chunk hard-cut can never
    # land between a MarkdownV2 `\` and the char it escapes.
    cap = Hive::Digest::MergedPr::Renderer::MAX_LABEL_LENGTH
    text = Hive::Digest::MergedPr::Renderer.render(
      [ pr(title: "x" * (cap + 50)) ], date: Date.new(2026, 6, 13), totals: totals
    )

    assert_includes text, "…"
    refute_includes text, "x" * (cap + 1)
  end

  def test_authoritative_row_count_survives_partial_measurement
    prs = 5.times.map { |index| pr(number: index + 1) }
    measured = totals(prs: 4, measured_prs: 4, additions: 40, deletions: 8, commits: 12)

    text = Hive::Digest::MergedPr::Renderer.render(
      prs, date: Date.new(2026, 6, 13), totals: measured
    )

    assert_includes text, "Lines \\+40/\\-8 · PRs 5 · Commits 12"
    refute_match(/partial|measured|~/, text)
  end

  def test_stats_blackout_keeps_pr_count_and_omits_measured_fields
    text = Hive::Digest::MergedPr::Renderer.render(
      [ pr(number: 1), pr(number: 2) ],
      date: Date.new(2026, 6, 13),
      totals: totals(prs: 2, measured_prs: 0)
    )

    assert_includes text, "──────────\nPRs 2"
    refute_includes text, "Lines "
    refute_includes text, "Commits "
  end

  def test_measured_zero_values_are_rendered_as_real_totals
    text = Hive::Digest::MergedPr::Renderer.render(
      [ pr ], date: Date.new(2026, 6, 13), totals: totals
    )

    assert_includes text, "Lines \\+0/\\-0 · PRs 1 · Commits 0"
  end

  private

  def pr(repo: "owner/repo", number: 1, title: "Title", merged_at: "2026-06-13T12:00:00Z",
         author: "alice", hive_slug: nil, hive_stage: nil)
    PR.new(
      repo: repo,
      number: number,
      title: title,
      url: "https://github.com/#{repo}/pull/#{number})",
      mergedAt: merged_at,
      author: author,
      authorIsBot: false,
      headRefName: "feature",
      isCrossRepository: false,
      hive_slug: hive_slug,
      hive_stage: hive_stage
    )
  end

  def totals(prs: 1, commits: 0, additions: 0, deletions: 0, measured_prs: 1)
    Hive::Digest::Totals.new(
      prs: prs,
      commits: commits,
      additions: additions,
      deletions: deletions,
      measured_prs: measured_prs
    )
  end
end
