require "test_helper"
require "hive/digest/stats"
require "hive/digest/shipped_item"

class HiveDigestStatsTest < Minitest::Test
  def test_sums_lines_and_commits_and_counts_prs
    fetched = []
    fetch = lambda do |url|
      fetched << url
      { additions: 100, deletions: 40, commits: 3 }
    end
    items = [ item(pr_number: 10), item(pr_number: 11) ]

    totals = Hive::Digest::Stats.new(fetch: fetch, logger: nil).for_items(items)

    assert_equal 2, totals.prs
    assert_equal 2, totals.measured_prs
    assert_equal 200, totals.additions
    assert_equal 80, totals.deletions
    assert_equal 6, totals.commits
    assert_equal 2, fetched.size, "every PR with a URL must be looked up"
  end

  def test_skips_items_without_a_pr_url
    fetch = ->(_url) { { additions: 1, deletions: 1, commits: 1 } }
    items = [ item(pr_number: 10), item(pr_number: 11, pr_url: "") ]

    totals = Hive::Digest::Stats.new(fetch: fetch, logger: nil).for_items(items)

    assert_equal 1, totals.prs, "an item with no PR URL must not count toward PRs"
    assert_equal 1, totals.measured_prs
  end

  def test_a_failed_pr_lookup_is_dropped_but_still_counts_as_a_pr
    fetch = lambda do |url|
      raise Hive::GhError, "gone" if url.end_with?("/11")

      { additions: 5, deletions: 2, commits: 1 }
    end
    items = [ item(pr_number: 10), item(pr_number: 11) ]

    totals = Hive::Digest::Stats.new(fetch: fetch, logger: nil).for_items(items)

    assert_equal 2, totals.prs, "a gone/private PR is still a shipped PR"
    assert_equal 1, totals.measured_prs, "only the successfully fetched PR is measured"
    assert_equal 5, totals.additions
    assert_equal 1, totals.commits
  end

  def test_no_measurable_prs_reports_zero_without_raising
    fetch = ->(_url) { raise Hive::GhError, "gh unavailable" }
    items = [ item(pr_number: 10) ]

    totals = Hive::Digest::Stats.new(fetch: fetch, logger: nil).for_items(items)

    assert_equal 1, totals.prs
    assert_equal 0, totals.measured_prs,
                 "when no stats can be fetched the renderer omits Lines/Commits"
  end

  private

  def item(pr_number:, pr_url: nil)
    Hive::Digest::ShippedItem.new(
      project_name: "alpha",
      slug: "slug-#{pr_number}",
      display_name: "Task #{pr_number}",
      pr_url: pr_url.nil? ? "https://example.test/pulls/#{pr_number}" : pr_url,
      pr_number: pr_number,
      pr_title: "Task #{pr_number}",
      pr_body: "body",
      shipped_at: Time.utc(2026, 6, 13, 12)
    )
  end
end
