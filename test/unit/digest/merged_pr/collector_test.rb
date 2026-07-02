require "test_helper"
require "hive/digest/merged_pr/collector"

class HiveDigestMergedPrCollectorTest < Minitest::Test
  include HiveTestHelper

  FakeGh = Struct.new(:responses, :calls) do
    def list_merged_prs(repo, since:, until_date:, cfg: nil)
      calls << { repo: repo, since: since, until_date: until_date, cfg: cfg }
      value = responses.fetch(repo)
      raise value if value.is_a?(Exception)

      value
    end
  end

  FakeMatcher = Struct.new(:matches, :calls) do
    def match(head_ref)
      calls << head_ref
      value = matches[head_ref]
      raise value if value.is_a?(Exception)

      value
    end
  end

  def test_filters_by_local_day_and_maps_metadata
    with_env("TZ" => "Europe/London") do
      gh = FakeGh.new({
        "owner/repo" => [
          pr(1, "2026-06-12T22:59:59Z"),
          pr(2, "2026-06-12T23:00:00Z", author: { "login" => "bot", "is_bot" => true },
                                           fork: true, head: "hive/task-260613-abcd"),
          pr(3, "2026-06-13T22:59:59Z"),
          pr(4, "2026-06-13T23:00:00Z")
        ]
      }, [])
      matcher = FakeMatcher.new({ "hive/task-260613-abcd" => { slug: "task-260613-abcd", stage: "9-done" } }, [])
      collector = Hive::Digest::MergedPr::Collector.new(gh: gh, matcher: matcher, cfg: { "cfg" => true }, logger: nil)

      prs = collector.for_date(Date.new(2026, 6, 13), repos: [ "owner/repo" ])

      assert_equal [ 2, 3 ], prs.map(&:number)
      assert_equal "bot", prs.first.author
      assert_equal true, prs.first.authorIsBot
      assert_equal true, prs.first.isCrossRepository
      assert_equal "task-260613-abcd", prs.first.hive_slug
      assert_equal "9-done", prs.first.hive_stage
      assert_equal({ repo: "owner/repo", since: "2026-06-12", until_date: "2026-06-14", cfg: { "cfg" => true } }, gh.calls.first)
    end
  end

  def test_repo_failure_is_dropped
    gh = FakeGh.new({
      "bad/repo" => Hive::GhError.new("boom"),
      "ok/repo" => [ pr(7, "2026-06-13T12:00:00Z") ]
    }, [])
    collector = Hive::Digest::MergedPr::Collector.new(gh: gh, matcher: FakeMatcher.new({}, []), logger: nil)

    prs = collector.for_date(Date.new(2026, 6, 13), repos: [ "bad/repo", "ok/repo" ])

    assert_equal [ 7 ], prs.map(&:number)
    assert_equal 1, collector.warnings.size
    assert_match(/dropping repo bad\/repo/, collector.warnings.first)
  end

  def test_matcher_error_is_swallowed_by_default_matcher_contract
    gh = FakeGh.new({ "owner/repo" => [ pr(1, "2026-06-13T12:00:00Z", head: "hive/x") ] }, [])
    matcher = FakeMatcher.new({ "hive/x" => RuntimeError.new("bad state") }, [])
    collector = Hive::Digest::MergedPr::Collector.new(gh: gh, matcher: matcher, logger: nil)

    prs = collector.for_date(Date.new(2026, 6, 13), repos: [ "owner/repo" ])

    assert_equal 1, prs.size
    assert_nil prs.first.hive_slug
  end

  private

  def pr(number, merged_at, author: { "login" => "alice", "is_bot" => false }, fork: false, head: "feature")
    {
      "number" => number,
      "title" => "Title #{number}",
      "url" => "https://github.com/owner/repo/pull/#{number}",
      "mergedAt" => merged_at,
      "author" => author,
      "headRefName" => head,
      "isCrossRepository" => fork
    }
  end
end
