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

    def digest_pr_diff_to_file(repository:, host:, number:, path:, cfg: nil, max_bytes: nil)
      value = digest_pr_diff(
        repository: repository, host: host, number: number, cfg: cfg, max_bytes: max_bytes
      )
      File.binwrite(path, value)
      File.chmod(0o600, path)
      value.bytesize
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
      assert_instance_of Hive::Digest::EvidenceFile, pr.body
      assert_instance_of Hive::Digest::EvidenceFile, pr.diff
      assert_includes File.binread(pr.body.path), "[REDACTED:github_token]"
      assert_includes File.binread(pr.diff.path), "[REDACTED:github_token]"
      refute_includes File.binread(pr.body.path), secret
      assert_equal [ "lib/change.rb" ], pr.files
      assert_equal 4, pr.additions
      assert_equal 2, pr.deletions
      assert_equal 3, pr.commits
      assert report.warnings.any? { |warning| warning.kind == "evidence_redacted" }
      assert gh.calls.all? { |call| call.fetch(:host) == "github.example.com" }
      report.cleanup!
      assert_empty Dir.children(scratch), "raw and redacted per-run scratch must be ephemeral"
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
        report.cleanup!
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
    assert_match(/invalid file header/, report.failures.first.message)
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

  def test_raw_diff_identity_accepts_asymmetrically_quoted_renames
    unicode_path = "lib/日本語.rb"
    quoted_unicode_a = '"a/lib/\346\227\245\346\234\254\350\252\236.rb"'
    quoted_unicode_b = '"b/lib/\346\227\245\346\234\254\350\252\236.rb"'

    to_ascii = fake_gh(diff: <<~DIFF)
      diff --git #{quoted_unicode_a} b/lib/ascii.rb
      similarity index 100%
      rename from lib/日本語.rb
      rename to lib/ascii.rb
    DIFF
    to_ascii.data[:files]["owner/repo#7"] = [ { "filename" => "lib/ascii.rb" } ]
    report = Hive::Digest::Collector.new(gh: to_ascii, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_equal [ "lib/ascii.rb" ], report.pull_requests.first.files
    report.cleanup!

    to_unicode = fake_gh(diff: <<~DIFF)
      diff --git a/lib/ascii.rb #{quoted_unicode_b}
      similarity index 100%
      rename from lib/ascii.rb
      rename to #{unicode_path}
    DIFF
    to_unicode.data[:files]["owner/repo#7"] = [ { "filename" => unicode_path } ]
    report = Hive::Digest::Collector.new(gh: to_unicode, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )
    assert_equal [ unicode_path ], report.pull_requests.first.files
    report.cleanup!
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

  def test_unexpected_exception_removes_the_collector_owned_run_directory
    with_tmp_dir do |scratch|
      collector = Hive::Digest::Collector.new(gh: fake_gh, logger: nil, scratch_root: scratch)
      collector.define_singleton_method(:collect_repository) { |*| raise NoMemoryError, "boom" }

      assert_raises(NoMemoryError) do
        collector.for_date(Date.new(2026, 6, 13), targets: [ target ])
      end
      assert_empty Dir.children(scratch)
    end
  end

  def test_legacy_diff_transport_is_written_to_private_scratch
    source = fake_gh
    legacy = Object.new
    %i[
      digest_repository_metadata digest_merged_pr_candidates digest_pr_detail
      digest_pr_files digest_pr_diff
    ].each do |name|
      legacy.define_singleton_method(name) { |**kwargs| source.public_send(name, **kwargs) }
    end

    report = Hive::Digest::Collector.new(gh: legacy, logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )

    assert_equal 1, report.pull_requests.size
    assert source.calls.any? { |call| call.fetch(:kind) == :diff }
    report.cleanup!
  end

  def test_diff_path_decoder_rejects_malformed_headers_and_accepts_named_escapes
    collector = Hive::Digest::Collector.new(gh: fake_gh, logger: nil)
    parse = lambda do |payload|
      collector.send(:parse_diff_header_paths, payload, expected_paths: [ "lib/change.rb" ])
    end

    assert_match(/invalid source path/, assert_raises(Hive::GhError) {
      parse.call('"x/lib/change.rb" b/lib/change.rb')
    }.message)
    assert_match(/invalid source path/, assert_raises(Hive::GhError) {
      parse.call("wrong b/lib/change.rb")
    }.message)
    assert_nil collector.send(:quoted_destination, 'a/lib/change.rb "unterminated')
    assert_match(/invalid quoted file header/, assert_raises(Hive::GhError) {
      collector.send(:decode_git_quoted_path, "not-quoted", 0)
    }.message)

    invalid_utf8 = ("\"".b + "\xFF".b + "\"".b)
    assert_match(/invalid UTF-8/, assert_raises(Hive::GhError) {
      collector.send(:decode_git_quoted_path, invalid_utf8, 0)
    }.message)
    assert_equal [ "a\n", 5 ], collector.send(:decode_git_quoted_path, '"a\n"', 0)
    assert_match(/invalid file escape/, assert_raises(Hive::GhError) {
      collector.send(:decode_git_quoted_path, '"a\z"', 0)
    }.message)
    assert_match(/unterminated/, assert_raises(Hive::GhError) {
      collector.send(:decode_git_quoted_path, '"a', 0)
    }.message)
  end

  def test_diff_path_guard_rejects_non_destination_paths
    collector = Hive::Digest::Collector.new(gh: fake_gh, logger: nil)
    collector.define_singleton_method(:parse_diff_header_paths) do |_payload, expected_paths:|
      "x/#{expected_paths.first}"
    end

    error = assert_raises(Hive::GhError) do
      collector.send(
        :diff_file_paths, "diff --git a/lib/change.rb b/lib/change.rb\n",
        expected_paths: [ "lib/change.rb" ]
      )
    end
    assert_match(/invalid destination path/, error.message)
  end

  def test_multiline_private_keys_are_redacted_as_one_evidence_block
    body = <<~BODY
      before
      -----BEGIN PRIVATE KEY-----
      private material
      -----END PRIVATE KEY-----
      after
    BODY
    report = Hive::Digest::Collector.new(gh: fake_gh(body: body), logger: nil).for_date(
      Date.new(2026, 6, 13), targets: [ target ]
    )

    text = File.binread(report.pull_requests.first.body.path)
    assert_includes text, "[REDACTED:pem_private_key]"
    refute_includes text, "private material"
    assert_includes text, "after"
    report.cleanup!
  end

  def test_file_redaction_checksum_and_io_failures_remove_partial_output
    with_tmp_dir do |dir|
      source = File.join(dir, "source")
      destination = File.join(dir, "destination")
      File.write(source, "safe\n")
      collector = Hive::Digest::Collector.new(gh: fake_gh, logger: nil)
      checksum = Struct.new(:hexdigest).new("0" * 64)

      with_replaced_singleton_method(::Digest::SHA256, :file, ->(_path) { checksum }) do
        assert_match(/checksum mismatch/, assert_raises(Hive::GhError) {
          collector.send(
            :redact_evidence_file, source, destination,
            target: target, number: 7, warnings: []
          )
        }.message)
      end

      missing = File.join(dir, "missing")
      assert_match(/redaction failed: Errno::ENOENT/, assert_raises(Hive::GhError) {
        collector.send(
          :redact_evidence_file, missing, destination,
          target: target, number: 7, warnings: []
        )
      }.message)
      refute File.exist?(destination)
    end
  end

  def test_body_bytes_are_checked_before_requesting_a_diff
    repository_limited = Hive::Digest::Collector.new(
      gh: fake_gh, logger: nil,
      limits: { per_pr: 100, per_repository: 3, per_digest: 100 }
    )
    repository_limited.instance_variable_set(:@digest_bytes, 0)
    assert_match(/repository evidence exceeds/, assert_raises(Hive::GhError) {
      repository_limited.send(:remaining_diff_bytes, 4, repository_bytes: 0)
    }.message)

    digest_limited = Hive::Digest::Collector.new(
      gh: fake_gh, logger: nil,
      limits: { per_pr: 100, per_repository: 100, per_digest: 3 }
    )
    digest_limited.instance_variable_set(:@digest_bytes, 0)
    assert_match(/digest evidence exceeds/, assert_raises(Hive::GhError) {
      digest_limited.send(:remaining_diff_bytes, 4, repository_bytes: 0)
    }.message)
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
