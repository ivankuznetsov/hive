require "test_helper"
require "hive/digest/collector"

class HiveDigestCollectorTest < Minitest::Test
  include HiveTestHelper

  FakeGh = Struct.new(:data, :calls) do
    def digest_repository_metadata(repository:, host:, cfg: nil)
      fetch(:metadata, repository, { repository: repository, host: host, cfg: cfg })
    end

    def digest_merged_pr_candidates(repository:, host:, window_start:, cfg: nil)
      fetch(:candidates, repository, { repository: repository, host: host, window_start: window_start, cfg: cfg })
    end

    def digest_pr_detail(repository:, host:, number:, cfg: nil)
      fetch(:detail, "#{repository}##{number}", { repository: repository, host: host, number: number, cfg: cfg })
    end

    def digest_pr_files(repository:, host:, number:, cfg: nil)
      fetch(:files, "#{repository}##{number}", { repository: repository, host: host, number: number, cfg: cfg })
    end

    def digest_pr_diff(repository:, host:, number:, cfg: nil)
      fetch(:diff, "#{repository}##{number}", { repository: repository, host: host, number: number, cfg: cfg })
    end

    private

    def fetch(kind, key, call)
      calls << call.merge(kind: kind)
      value = data.fetch(kind).fetch(key)
      raise value if value.is_a?(Exception)

      value
    end
  end

  def test_collects_complete_pr_evidence_redacts_secrets_and_cleans_raw_scratch
    with_tmp_dir do |scratch|
      secret = "ghp_#{'a' * 36}"
      gh = fake_gh(
        body: "Implements migration with #{secret}",
        diff: diff_fixture("lib/change.rb", "+token=#{secret}")
      )
      collector = Hive::Digest::Collector.new(gh: gh, cfg: { "x" => 1 }, logger: nil, scratch_root: scratch)

      report = collector.for_date(Date.new(2026, 6, 13), targets: [ target ])

      assert_equal 1, report.collected_count
      assert_equal 1, report.pull_requests.size
      pr = report.pull_requests.first
      assert_includes pr.body, "[REDACTED:github_token]"
      assert_includes pr.diff, "[REDACTED:github_token]"
      refute_includes pr.body, secret
      assert_equal [ "lib/change.rb" ], pr.files
      assert_equal 4, pr.additions
      assert_equal 2, pr.deletions
      assert_equal 3, pr.commits
      assert report.warnings.any? { |warning| warning.kind == "evidence_redacted" }
      assert_empty Dir.children(scratch), "raw and redacted per-run scratch must be ephemeral"
      assert gh.calls.all? { |call| call.fetch(:host) == "github.example.com" }
    end
  end

  def test_successful_empty_repository_is_distinct_from_failed_repository
    good = target(repository: "owner/good", project_name: "Good")
    bad = target(repository: "owner/bad", project_name: "Bad")
    gh = fake_gh(repository: "owner/good", candidates: [])
    gh.data[:metadata]["owner/bad"] = Hive::GhError.new("provider unavailable")

    report = Hive::Digest::Collector.new(gh: gh, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ bad, good ]
    )

    assert_equal 2, report.resolved_count
    assert_equal [ "owner/good" ], report.repositories.map { |repo| repo.target.repository }
    assert_empty report.pull_requests
    assert_equal [ "owner/bad" ], report.failures.map(&:repository)
    refute report.all_failed?
  end

  def test_all_failed_report_is_mechanically_detectable
    gh = fake_gh
    gh.data[:metadata]["owner/repo"] = Hive::GhError.new("outage")

    report = Hive::Digest::Collector.new(gh: gh, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )

    assert report.all_failed?
    assert_equal 1, report.failures.size
    assert_equal "repository_collection_failed", report.warnings.first.kind
  end

  def test_one_missing_required_diff_fails_the_whole_repository
    gh = fake_gh(diff: "")

    report = Hive::Digest::Collector.new(gh: gh, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )

    assert report.all_failed?
    assert_match(/raw diff is empty/, report.failures.first.message)
  end

  def test_changed_file_identity_mismatch_fails_the_repository
    gh = fake_gh(diff: diff_fixture("other.rb", "+change"))

    report = Hive::Digest::Collector.new(gh: gh, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )

    assert report.all_failed?
    assert_match(/identity mismatch/, report.failures.first.message)
  end

  def test_safety_ceiling_breach_is_a_repository_failure
    gh = fake_gh(body: "large body", diff: diff_fixture("lib/change.rb", "+change"))
    collector = Hive::Digest::Collector.new(
      gh: gh,
      logger: nil,
      limits: { per_pr: 5, per_repository: 100, per_digest: 100 }
    )

    report = collector.for_date(Date.new(2026, 6, 13), targets: [ target ])

    assert report.all_failed?
    assert_match(/safety ceiling/, report.failures.first.message)
  end

  def test_optional_malformed_metric_is_preserved_as_unknown
    gh = fake_gh
    gh.data[:detail]["owner/repo#7"]["commits"] = "unknown"

    pr = Hive::Digest::Collector.new(gh: gh, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    ).pull_requests.first

    assert_nil pr.commits
    assert_equal 4, pr.additions
  end

  private

  def target(repository: "owner/repo", project_name: "Project")
    Hive::Digest::RepositoryTarget.new(
      project_name: project_name,
      path: "/tmp/#{project_name.downcase}",
      repository: repository,
      host: "github.example.com"
    )
  end

  def fake_gh(repository: "owner/repo", candidates: nil, body: "Body", diff: nil)
    merged_at = "2026-06-13T12:00:00Z"
    candidates ||= [ { "number" => 7, "updated_at" => merged_at, "merged_at" => merged_at } ]
    FakeGh.new(
      {
        metadata: {
          repository => {
            "full_name" => repository,
            "html_url" => "https://github.example.com/#{repository}",
            "description" => "Repository description"
          }
        },
        candidates: { repository => candidates },
        detail: {
          "#{repository}#7" => {
            "number" => 7,
            "html_url" => "https://github.example.com/#{repository}/pull/7",
            "title" => "Ship the change",
            "body" => body,
            "merged_at" => merged_at,
            "changed_files" => 1,
            "additions" => 4,
            "deletions" => 2,
            "commits" => 3
          }
        },
        files: { "#{repository}#7" => [ { "filename" => "lib/change.rb" } ] },
        diff: { "#{repository}#7" => diff || diff_fixture("lib/change.rb", "+change") }
      },
      []
    )
  end

  def diff_fixture(path, change)
    <<~DIFF
      diff --git a/#{path} b/#{path}
      index 1111111..2222222 100644
      --- a/#{path}
      +++ b/#{path}
      @@ -1 +1 @@
      #{change}
    DIFF
  end
end
