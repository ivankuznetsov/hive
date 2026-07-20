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

    def digest_pr_diff(repository:, host:, number:, cfg: nil, max_bytes: nil)
      fetch(
        :diff, "#{repository}##{number}",
        { repository: repository, host: host, number: number, cfg: cfg, max_bytes: max_bytes }
      )
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

  def test_closed_unmerged_candidates_are_skipped_without_failing_collection
    candidates = [
      { "number" => 6, "updated_at" => "2026-06-13T13:00:00Z", "merged_at" => nil },
      { "number" => 7, "updated_at" => "2026-06-13T12:00:00Z", "merged_at" => "2026-06-13T12:00:00Z" }
    ]

    report = Hive::Digest::Collector.new(gh: fake_gh(candidates: candidates), logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )

    assert_equal [ 7 ], report.pull_requests.map(&:number)
    assert_empty report.failures
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

  def test_repository_and_digest_safety_ceilings_fail_the_repository
    merged_at = "2026-06-13T13:00:00Z"
    gh = fake_gh(candidates: [
      { "number" => 7, "updated_at" => "2026-06-13T12:00:00Z", "merged_at" => "2026-06-13T12:00:00Z" },
      { "number" => 8, "updated_at" => merged_at, "merged_at" => merged_at }
    ])
    add_pr(gh, number: 8, merged_at: merged_at)
    report = Hive::Digest::Collector.new(
      gh: gh, logger: nil,
      limits: { per_pr: 1_000, per_repository: 200, per_digest: 1_000 }
    ).for_date(Date.new(2026, 6, 13), targets: [ target ])
    assert report.all_failed?
    assert_match(/repository evidence exceeds/, report.failures.first.message)

    report = Hive::Digest::Collector.new(
      gh: fake_gh, logger: nil,
      limits: { per_pr: 1_000, per_repository: 1_000, per_digest: 5 }
    ).for_date(Date.new(2026, 6, 13), targets: [ target ])
    assert report.all_failed?
    assert_match(/digest evidence exceeds/, report.failures.first.message)
  end

  def test_checksum_mismatch_fails_the_repository_and_removes_raw_files
    with_tmp_dir do |scratch|
      digest_override = ->(_content) { "0" * 64 }
      with_replaced_singleton_method(::Digest::SHA256, :hexdigest, digest_override) do
        report = Hive::Digest::Collector.new(gh: fake_gh, logger: nil, scratch_root: scratch).for_date(
          Date.new(2026, 6, 13), targets: [ target ]
        )
        assert report.all_failed?
        assert_match(/checksum mismatch/, report.failures.first.message)
      end
      assert_empty Dir.children(scratch)
    end
  end

  def test_candidate_identity_changes_and_malformed_identity_fail_the_repository
    changed = fake_gh
    changed.data[:detail]["owner/repo#7"]["merged_at"] = "2026-06-13T13:00:00Z"
    report = Hive::Digest::Collector.new(gh: changed, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_match(/identity changed/, report.failures.first.message)

    malformed = fake_gh
    malformed.data[:detail]["owner/repo#7"]["merged_at"] = "not-a-time"
    report = Hive::Digest::Collector.new(gh: malformed, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_match(/malformed pull-request identity/, report.failures.first.message)
  end

  def test_changed_file_count_and_metadata_fail_closed
    count_mismatch = fake_gh
    count_mismatch.data[:detail]["owner/repo#7"]["changed_files"] = 2
    report = Hive::Digest::Collector.new(gh: count_mismatch, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_match(/changed-file count mismatch/, report.failures.first.message)

    malformed = fake_gh
    malformed.data[:files]["owner/repo#7"] = [ {} ]
    report = Hive::Digest::Collector.new(gh: malformed, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_match(/malformed changed-file metadata/, report.failures.first.message)
  end

  def test_invalid_raw_diff_header_fails_the_repository
    gh = fake_gh(diff: "diff --git \"unterminated\n")
    report = Hive::Digest::Collector.new(gh: gh, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert report.all_failed?
    assert_match(/unterminated quoted file path/, report.failures.first.message)
  end

  def test_raw_diff_identity_accepts_spaces_and_git_c_quoted_unicode_paths
    spaced = fake_gh(diff: diff_fixture("lib/file with spaces.rb", "+change"))
    spaced.data[:files]["owner/repo#7"] = [ { "filename" => "lib/file with spaces.rb" } ]
    spaced_report = Hive::Digest::Collector.new(gh: spaced, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_equal [ "lib/file with spaces.rb" ], spaced_report.pull_requests.first.files

    unicode_path = "lib/日本語 file.rb"
    quoted = <<~DIFF
      diff --git "a/lib/\\346\\227\\245\\346\\234\\254\\350\\252\\236 file.rb" "b/lib/\\346\\227\\245\\346\\234\\254\\350\\252\\236 file.rb"
      index 1111111..2222222 100644
      --- "a/lib/\\346\\227\\245\\346\\234\\254\\350\\252\\236 file.rb"
      +++ "b/lib/\\346\\227\\245\\346\\234\\254\\350\\252\\236 file.rb"
      @@ -1 +1 @@
      +change
    DIFF
    unicode = fake_gh(diff: quoted)
    unicode.data[:files]["owner/repo#7"] = [ { "filename" => unicode_path } ]
    unicode_report = Hive::Digest::Collector.new(gh: unicode, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_equal [ unicode_path ], unicode_report.pull_requests.first.files
  end

  def test_redaction_verification_and_runtime_errors_fail_the_repository
    unsafe = Object.new
    unsafe.define_singleton_method(:scan) { |_text| [ { name: :token } ] }
    unsafe.define_singleton_method(:redact) { |text| text }
    report = Hive::Digest::Collector.new(gh: fake_gh, logger: nil, redactor: unsafe).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_match(/could not be verified/, report.failures.first.message)

    broken = Object.new
    broken.define_singleton_method(:scan) { |_text| raise EncodingError, "invalid" }
    broken.define_singleton_method(:redact) { |text| text }
    report = Hive::Digest::Collector.new(gh: fake_gh, logger: nil, redactor: broken).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_match(/redaction failed: EncodingError/, report.failures.first.message)
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

  def add_pr(gh, number:, merged_at:)
    key = "owner/repo##{number}"
    gh.data[:detail][key] = {
      "number" => number,
      "html_url" => "https://github.example.com/owner/repo/pull/#{number}",
      "title" => "Ship another change",
      "body" => "Another body",
      "merged_at" => merged_at,
      "changed_files" => 1,
      "additions" => 1,
      "deletions" => 1,
      "commits" => 1
    }
    gh.data[:files][key] = [ { "filename" => "lib/change.rb" } ]
    gh.data[:diff][key] = diff_fixture("lib/change.rb", "+another change")
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
