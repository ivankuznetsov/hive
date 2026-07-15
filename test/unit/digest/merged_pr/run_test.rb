require "test_helper"
require "hive/digest/merged_pr"
require "hive/digest/stats"

class HiveDigestMergedPrRunTest < Minitest::Test
  PR = Hive::Digest::MergedPr::PullRequest

  FakeResolver = Struct.new(:result, :calls) do
    def resolve(repos:)
      calls << repos
      result
    end
  end

  FakeCollector = Struct.new(:prs, :warnings, :calls) do
    def for_date(date, repos:)
      calls << { date: date, repos: repos }
      prs
    end
  end

  FakeSender = Struct.new(:preflight_calls, :deliveries, :chat_id) do
    def preflight!
      preflight_calls << true
    end

    def deliver(text, dry_run:)
      deliveries << { text: text, dry_run: dry_run }
      Hive::Digest::Sender::SendResult.new(chat_id: dry_run ? nil : chat_id, responses: [], dry_run: dry_run, text: text)
    end
  end

  FakeStats = Struct.new(:totals, :calls) do
    def for_items(items)
      calls << items
      totals
    end
  end

  def test_dry_run_resolves_collects_and_returns_message_without_preflight
    resolver = FakeResolver.new(Hive::Digest::MergedPr::Resolution.new(repos: [ "owner/repo" ], warnings: []), [])
    collector = FakeCollector.new([ pr ], [], [])
    sender = FakeSender.new([], [], 4242)
    stats = FakeStats.new(totals(prs: 1, measured_prs: 1, additions: 7, deletions: 2, commits: 1), [])

    result = Hive::Digest::MergedPr.run(
      date: Date.new(2026, 6, 13),
      dry_run: true,
      repos: [ "owner/repo" ],
      cfg: {},
      resolver: resolver,
      collector: collector,
      stats: stats,
      sender: sender
    )

    assert_equal [ [ "owner/repo" ] ], resolver.calls
    assert_equal [ { date: Date.new(2026, 6, 13), repos: [ "owner/repo" ] } ], collector.calls
    assert_empty sender.preflight_calls
    assert_equal true, sender.deliveries.first.fetch(:dry_run)
    assert_equal 1, result.count
    assert_equal [ [ pr ] ], stats.calls
    assert_includes result.message, "Lines \\+7/\\-2 · PRs 1 · Commits 1"
    refute_includes result.message, "Total:"
  end

  def test_real_run_preflights_and_sets_chat_id
    resolver = FakeResolver.new(Hive::Digest::MergedPr::Resolution.new(repos: [ "owner/repo" ], warnings: []), [])
    collector = FakeCollector.new([], [], [])
    sender = FakeSender.new([], [], 4242)

    result = Hive::Digest::MergedPr.run(
      date: Date.new(2026, 6, 13),
      dry_run: false,
      cfg: {},
      resolver: resolver,
      collector: collector,
      sender: sender
    )

    assert_equal [ true ], sender.preflight_calls
    assert_equal false, sender.deliveries.first.fetch(:dry_run)
    assert_equal 4242, result.delivery.chat_id
    assert_equal 0, result.count
    assert_includes result.message, "PRs 0"
  end

  def test_default_date_uses_previous_local_day
    resolver = FakeResolver.new(Hive::Digest::MergedPr::Resolution.new(repos: [ "owner/repo" ], warnings: []), [])
    collector = FakeCollector.new([], [], [])
    sender = FakeSender.new([], [], nil)

    result = Hive::Digest::MergedPr.run(
      dry_run: true,
      cfg: {},
      clock: -> { Time.local(2026, 6, 14, 9, 0, 0) },
      resolver: resolver,
      collector: collector,
      sender: sender
    )

    assert_equal Date.new(2026, 6, 13), result.date
  end

  def test_zero_automatic_repo_scope_stops_before_collection_or_delivery
    resolver = Object.new
    resolver.define_singleton_method(:resolve) do |repos:|
      raise Hive::ConfigError,
            "hive digest: no repositories resolved from registered projects; supply --repo"
    end
    collector = FakeCollector.new([], [], [])
    sender = FakeSender.new([], [], 4242)

    error = assert_raises(Hive::ConfigError) do
      Hive::Digest::MergedPr.run(
        date: Date.new(2026, 6, 13),
        dry_run: true,
        cfg: {},
        resolver: resolver,
        collector: collector,
        sender: sender
      )
    end

    assert_match(/no repositories resolved/, error.message)
    assert_empty collector.calls
    assert_empty sender.preflight_calls
    assert_empty sender.deliveries
  end

  def test_one_failed_stats_fetch_aggregates_measured_prs_and_still_delivers
    prs = 5.times.map { |index| pr(number: index + 1) }
    stats = Hive::Digest::Stats.new(
      fetch: lambda { |url|
        raise Hive::GhError, "gone" if url.end_with?("/3")

        { additions: 10, deletions: 2, commits: 3 }
      },
      logger: nil
    )
    sender = FakeSender.new([], [], nil)

    result = run_with(prs: prs, stats: stats, sender: sender)

    assert_equal 5, result.count
    assert_equal prs, result.prs
    assert_includes result.message, "Lines \\+40/\\-8 · PRs 5 · Commits 12"
    refute_match(/partial|measured|~/, result.message)
    assert_equal 1, sender.deliveries.size
  end

  def test_stats_blackout_logs_once_and_delivers_pr_count_only
    logger = CapturingLogger.new
    stats = Hive::Digest::Stats.new(
      fetch: ->(_url) { raise Hive::GhError, "gh unavailable" }, logger: logger
    )
    sender = FakeSender.new([], [], nil)

    result = run_with(prs: [ pr(number: 1), pr(number: 2) ], stats: stats, sender: sender)

    assert_includes result.message, "──────────\nPRs 2"
    refute_includes result.message, "Lines "
    refute_includes result.message, "Commits "
    assert_equal 1, logger.errors.grep(/measured 0\/2 PRs/).size
    assert_equal 1, sender.deliveries.size
  end

  def test_empty_day_skips_stats_fetch_and_still_sends_prs_zero
    stats = Hive::Digest::Stats.new(fetch: ->(_url) { flunk "must not fetch" }, logger: nil)
    sender = FakeSender.new([], [], 4242)

    result = run_with(prs: [], stats: stats, sender: sender, dry_run: false)

    assert_equal 0, result.count
    assert_includes result.message, "──────────\nPRs 0"
    assert_equal [ true ], sender.preflight_calls
    assert_equal 1, sender.deliveries.size
  end

  private

  class CapturingLogger
    attr_reader :errors

    def initialize
      @errors = []
    end

    def error(message) = @errors << message
    def warn(_message); end
  end

  def run_with(prs:, stats:, sender:, dry_run: true)
    resolver = FakeResolver.new(
      Hive::Digest::MergedPr::Resolution.new(repos: [ "owner/repo" ], warnings: []), []
    )
    collector = FakeCollector.new(prs, [], [])
    Hive::Digest::MergedPr.run(
      date: Date.new(2026, 6, 13),
      dry_run: dry_run,
      cfg: {},
      resolver: resolver,
      collector: collector,
      stats: stats,
      sender: sender
    )
  end

  def totals(prs:, measured_prs:, additions: 0, deletions: 0, commits: 0)
    Hive::Digest::Totals.new(
      prs: prs,
      measured_prs: measured_prs,
      additions: additions,
      deletions: deletions,
      commits: commits
    )
  end

  def pr(number: 1)
    PR.new(
      repo: "owner/repo",
      number: number,
      title: "Title",
      url: "https://github.com/owner/repo/pull/#{number}",
      mergedAt: "2026-06-13T12:00:00Z",
      author: "alice",
      authorIsBot: false,
      headRefName: "feature",
      isCrossRepository: false,
      hive_slug: nil,
      hive_stage: nil
    )
  end
end
