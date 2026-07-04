require "test_helper"
require "hive/digest/merged_pr/renderer"

class HiveDigestMergedPrRendererTest < Minitest::Test
  PR = Hive::Digest::MergedPr::PullRequest

  def test_renders_grouped_totals_and_chronological_lines
    prs = [
      pr(repo: "b/repo", number: 3, merged_at: "2026-06-13T12:00:00Z"),
      pr(repo: "a/repo", number: 2, merged_at: "2026-06-13T11:00:00Z", author: "bob"),
      pr(repo: "a/repo", number: 1, merged_at: "2026-06-13T10:00:00Z", title: "Fix (docs)")
    ]

    text = Hive::Digest::MergedPr::Renderer.render(prs, date: Date.new(2026, 6, 13))

    assert_includes text, "Merged PR digest — 2026\\-06\\-13"
    assert_includes text, "Total: 3 PRs"
    assert_operator text.index("`a/repo — 2`"), :<, text.index("`b/repo — 1`")
    assert_operator text.index("\\#1 Fix \\(docs\\)"), :<, text.index("\\#2 Title")
  end

  def test_hive_match_replaces_author_suffix
    text = Hive::Digest::MergedPr::Renderer.render(
      [ pr(hive_slug: "task-260613-abcd", hive_stage: "9-done") ],
      date: Date.new(2026, 6, 13)
    )

    assert_includes text, "Hive task matched"
    refute_includes text, "alice"
  end

  def test_empty_day_renders_zero_count
    text = Hive::Digest::MergedPr::Renderer.render([], date: Date.new(2026, 6, 13))

    assert_equal "Merged PR digest — 2026\\-06\\-13\n\nTotal: 0 PRs", text
  end

  def test_long_title_is_length_capped_before_escaping
    # Mirror the sibling renderer's cap so a Telegram chunk hard-cut can never
    # land between a MarkdownV2 `\` and the char it escapes.
    cap = Hive::Digest::MergedPr::Renderer::MAX_LABEL_LENGTH
    text = Hive::Digest::MergedPr::Renderer.render(
      [ pr(title: "x" * (cap + 50)) ], date: Date.new(2026, 6, 13)
    )

    assert_includes text, "…"
    refute_includes text, "x" * (cap + 1)
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
end
