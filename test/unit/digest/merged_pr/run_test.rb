require "test_helper"
require "json_schemer"
require "hive/digest/merged_pr"

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

  def test_dry_run_resolves_collects_and_returns_message_without_preflight
    resolver = FakeResolver.new(Hive::Digest::MergedPr::Resolution.new(repos: [ "owner/repo" ], warnings: []), [])
    collector = FakeCollector.new([ pr ], [], [])
    sender = FakeSender.new([], [], 4242)

    result = Hive::Digest::MergedPr.run(
      date: Date.new(2026, 6, 13),
      dry_run: true,
      repos: [ "owner/repo" ],
      cfg: {},
      resolver: resolver,
      collector: collector,
      sender: sender
    )

    assert_equal [ [ "owner/repo" ] ], resolver.calls
    assert_equal [ { date: Date.new(2026, 6, 13), repos: [ "owner/repo" ] } ], collector.calls
    assert_empty sender.preflight_calls
    assert_equal true, sender.deliveries.first.fetch(:dry_run)
    assert_equal 1, result.count
    assert_includes result.message, "Total: 1 PR"
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
  end

  def test_default_date_uses_previous_local_day
    resolver = FakeResolver.new(Hive::Digest::MergedPr::Resolution.new(repos: [], warnings: []), [])
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

  private

  def pr
    PR.new(
      repo: "owner/repo",
      number: 1,
      title: "Title",
      url: "https://github.com/owner/repo/pull/1",
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
