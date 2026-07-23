require "test_helper"
require "hive/digest/stats"

class HiveDigestStatsTest < Minitest::Test
  def test_sums_known_values_and_preserves_true_zero
    repository = canonical_repository([
      canonical_pr(number: 1, additions: 0, deletions: 2, commits: 1),
      canonical_pr(number: 2, additions: 5, deletions: 0, commits: 2)
    ])

    report = Hive::Digest::Stats.new.for_repositories([ repository ])

    assert_equal 2, report.overall.pr_count
    assert_equal 5, report.overall.metric(:additions).value
    assert_equal 2, report.overall.metric(:deletions).value
    assert_equal 3, report.overall.metric(:commits).value
    assert report.overall.metric(:additions).complete?
    assert_empty report.warnings
  end

  def test_partial_totals_sum_only_measured_values_and_warn_per_pr_metric
    repository = canonical_repository([
      canonical_pr(number: 1, additions: 5, deletions: nil, commits: 1),
      canonical_pr(number: 2, additions: nil, deletions: nil, commits: 0)
    ])

    report = Hive::Digest::Stats.new.for_repositories([ repository ])

    additions = report.overall.metric(:additions)
    assert_equal 5, additions.value
    assert additions.partial?
    deletions = report.overall.metric(:deletions)
    assert_nil deletions.value
    assert deletions.unavailable?
    assert_equal 2, report.warnings.size
    assert_equal [ "deletions" ], report.warnings.find { |warning| warning.pr_number == 1 }.metrics
    assert_equal %w[additions deletions], report.warnings.find { |warning| warning.pr_number == 2 }.metrics
  end

  def test_empty_scope_has_pr_count_only_and_no_invented_metrics
    report = Hive::Digest::Stats.new.for_repositories([ canonical_repository([]) ])

    assert_equal 0, report.overall.pr_count
    Hive::Digest::PR_METRICS.each do |metric|
      total = report.overall.metric(metric)
      assert_nil total.value
      assert total.complete?
    end
    assert_empty report.warnings
  end

  def test_same_slug_on_different_hosts_keeps_distinct_repository_totals
    public_target = target_for("github.com")
    enterprise_target = target_for("github.example.com")
    repositories = [
      repository_for(public_target, [ pr_for(public_target, additions: 2) ]),
      repository_for(enterprise_target, [ pr_for(enterprise_target, additions: 7) ])
    ]

    report = Hive::Digest::Stats.new.for_repositories(repositories)

    assert_equal 2, report.by_repository.fetch(public_target.key).metric(:additions).value
    assert_equal 7, report.by_repository.fetch(enterprise_target.key).metric(:additions).value
  end

  def test_metric_guards_reject_impossible_coverage_and_values
    assert_raises(ArgumentError) do
      Hive::Digest::MetricTotal.new(value: 1, known_count: 2, contributor_count: 1)
    end
    assert_raises(ArgumentError) do
      Hive::Digest::MetricTotal.new(value: nil, known_count: 1, contributor_count: 1)
    end
    assert_raises(ArgumentError) do
      Hive::Digest::MetricTotal.new(value: -1, known_count: 1, contributor_count: 1)
    end
  end

  private

  def canonical_repository(prs)
    Hive::Digest::RepositoryCollection.new(
      target: canonical_target,
      metadata: Hive::Digest::RepositoryMetadata.new(
        name: "owner/repo", description: "Description", url: "https://github.com/owner/repo"
      ),
      pull_requests: prs
    )
  end

  def canonical_pr(number:, additions:, deletions:, commits:)
    Hive::Digest::PullRequest.new(
      target: canonical_target, number: number, title: "PR #{number}",
      url: "https://github.com/owner/repo/pull/#{number}",
      merged_at: Time.utc(2026, 6, 13, 12, number), body: "Body",
      diff: "diff --git a/a b/a", files: [ "a" ], additions: additions,
      deletions: deletions, commits: commits
    )
  end

  def canonical_target
    @canonical_target ||= Hive::Digest::RepositoryTarget.new(
      project_name: "Project", path: "/tmp/project", repository: "owner/repo", host: "github.com"
    )
  end

  def target_for(host)
    Hive::Digest::RepositoryTarget.new(
      project_name: host, path: "/tmp/#{host}", repository: "owner/repo", host: host
    )
  end

  def repository_for(target, prs)
    Hive::Digest::RepositoryCollection.new(
      target: target,
      metadata: Hive::Digest::RepositoryMetadata.new(
        name: "owner/repo", description: target.host, url: "https://#{target.host}/owner/repo"
      ),
      pull_requests: prs
    )
  end

  def pr_for(target, additions:)
    Hive::Digest::PullRequest.new(
      target: target, number: 7, title: "PR 7", url: "https://#{target.host}/owner/repo/pull/7",
      merged_at: Time.utc(2026, 6, 13, 12), body: "Body", diff: "diff --git a/a b/a",
      files: [ "a" ], additions: additions, deletions: 0, commits: 1
    )
  end
end
