require "test_helper"
require "hive/gh"

class HiveGhDigestTest < Minitest::Test
  include HiveTestHelper

  def test_merged_pr_candidates_paginate_until_all_rows_predate_window_and_deduplicate
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    calls = []
    responses = [
      [ JSON.generate([ row(1, "2026-06-13T10:00:00Z"), row(2, "2026-06-13T09:00:00Z") ]), "", ok ],
      [ JSON.generate([ row(2, "2026-06-12T22:00:00Z"), row(3, "2026-06-12T21:00:00Z") ]), "", ok ]
    ]

    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*args, **|
      calls << args
      responses.shift
    }) do
      rows = Hive::Gh.digest_merged_pr_candidates(
        repository: "owner/repo", host: "github.example.com",
        window_start: Time.utc(2026, 6, 12, 23)
      )

      assert_equal [ 1, 2, 3 ], rows.map { |item| item.fetch("number") }
    end
    assert_equal 2, calls.size
    assert calls.all? { |args| args.include?("--hostname") && args.include?("github.example.com") }
    assert_includes calls.last.last, "page=2"
  end

  def test_merged_pr_candidates_reject_malformed_page_and_page_cap
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    response = [ JSON.generate([ { "number" => 1 } ]), "", ok ]
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { response }) do
      assert_raises(Hive::GhError) do
        Hive::Gh.digest_merged_pr_candidates(
          repository: "owner/repo", host: "github.com", window_start: Time.utc(2026, 6, 13)
        )
      end
    end

    response = [ JSON.generate([ row(1, "2026-06-13T10:00:00Z") ]), "", ok ]
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { response }) do
      assert_match(/exceeded/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_merged_pr_candidates(
          repository: "owner/repo", host: "github.com",
          window_start: Time.utc(2026, 6, 13), max_pages: 1
        )
      }.message)
    end
  end

  def test_merged_pr_candidates_exclude_closed_unmerged_rows
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    closed = row(1, "2026-06-13T10:00:00Z").merge("merged_at" => nil)
    merged = row(2, "2026-06-12T22:00:00Z")
    responses = [
      [ JSON.generate([ closed, merged ]), "", ok ],
      [ JSON.generate([]), "", ok ]
    ]

    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
      rows = Hive::Gh.digest_merged_pr_candidates(
        repository: "owner/repo", host: "github.com", window_start: Time.utc(2026, 6, 13)
      )
      assert_equal [ 2 ], rows.map { |item| item.fetch("number") }
    end
  end

  def test_detail_diff_and_files_use_explicit_host_and_validate_shapes
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    calls = []
    detail = {
      "number" => 7,
      "html_url" => "https://github.example.com/owner/repo/pull/7",
      "title" => "Title",
      "body" => nil,
      "merged_at" => "2026-06-13T12:00:00Z",
      "changed_files" => 1
    }
    responses = [
      [ JSON.generate(detail), "", ok ],
      [ "raw diff", "", ok ],
      [ JSON.generate([ [ { "filename" => "lib/a.rb" } ] ]), "", ok ]
    ]
    with_replaced_singleton_method(Hive::Gh, :capture3, lambda { |*args, **|
      calls << args
      responses.shift
    }) do
      assert_equal detail, Hive::Gh.digest_pr_detail(
        repository: "owner/repo", host: "github.example.com", number: 7
      )
      assert_equal "raw diff", Hive::Gh.digest_pr_diff(
        repository: "owner/repo", host: "github.example.com", number: 7
      )
      assert_equal [ "lib/a.rb" ], Hive::Gh.digest_pr_files(
        repository: "owner/repo", host: "github.example.com", number: 7
      ).map { |file| file.fetch("filename") }
    end

    assert calls.all? { |args| args.include?("--hostname") && args.include?("github.example.com") }
    assert calls[1].include?("Accept: application/vnd.github.diff")
    assert calls[2].include?("--paginate")
  end

  def test_candidate_pagination_rejects_page_shape_order_and_invalid_limits
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    responses = [
      [ "{}", "", ok ],
      [ JSON.generate([ row(1, "2026-06-13T09:00:00Z"), row(2, "2026-06-13T10:00:00Z") ]), "", ok ]
    ]
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
      assert_match(/incomplete pull-request page/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_merged_pr_candidates(
          repository: "owner/repo", host: "github.com", window_start: Time.utc(2026, 6, 13)
        )
      }.message)
      assert_match(/out of updated_at order/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_merged_pr_candidates(
          repository: "owner/repo", host: "github.com", window_start: Time.utc(2026, 6, 13)
        )
      }.message)
    end

    assert_match(/invalid merged-PR pagination input/, assert_raises(Hive::GhError) {
      Hive::Gh.digest_merged_pr_candidates(
        repository: "owner/repo", host: "github.com",
        window_start: Time.utc(2026, 6, 13), max_pages: Object.new
      )
    }.message)
  end

  def test_repository_metadata_validates_shape_and_json
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    valid = {
      "full_name" => "Owner/Repo",
      "html_url" => "https://github.example.com/Owner/Repo",
      "description" => nil
    }
    responses = [
      [ JSON.generate(valid), "", ok ],
      [ JSON.generate({ "full_name" => "other/repo" }), "", ok ],
      [ "{", "", ok ]
    ]
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
      assert_equal valid, Hive::Gh.digest_repository_metadata(
        repository: "owner/repo", host: "github.example.com"
      )
      assert_match(/malformed repository metadata/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_repository_metadata(repository: "owner/repo", host: "github.example.com")
      }.message)
      assert_match(/unparseable/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_repository_metadata(repository: "owner/repo", host: "github.example.com")
      }.message)
    end
  end

  def test_detail_rejects_malformed_shape_inputs_times_and_urls
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    base = {
      "number" => 7,
      "html_url" => "https://github.com/owner/repo/pull/7",
      "title" => "Title",
      "body" => "Body",
      "merged_at" => "2026-06-13T12:00:00Z",
      "changed_files" => 1
    }
    invalid_time = base.merge("merged_at" => "not-a-time")
    invalid_url = base.merge("html_url" => "http://[")
    responses = [
      [ "{}", "", ok ],
      [ JSON.generate(invalid_time), "", ok ],
      [ JSON.generate(invalid_url), "", ok ]
    ]
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
      assert_match(/malformed pull-request detail/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_pr_detail(repository: "owner/repo", host: "github.com", number: 7)
      }.message)
      assert_match(/merged_at.*invalid/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_pr_detail(repository: "owner/repo", host: "github.com", number: 7)
      }.message)
      assert_match(/URL is invalid/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_pr_detail(repository: "owner/repo", host: "github.com", number: 7)
      }.message)
    end
    assert_match(/invalid pull-request detail input/, assert_raises(Hive::GhError) {
      Hive::Gh.digest_pr_detail(repository: "owner/repo", host: "github.com", number: Object.new)
    }.message)
  end

  def test_diff_and_files_wrap_transport_shape_parse_and_input_failures
    ok = Hive::Gh::CommandStatus.new(exitstatus: 0)
    failed = Hive::Gh::CommandStatus.new(exitstatus: 1)
    secret = "ghp_#{'z' * 36}"
    responses = [
      [ secret, "", failed ],
      [ "{}", "", ok ],
      [ JSON.generate([ [ {} ] ]), "", ok ],
      [ "{", "", ok ]
    ]
    with_replaced_singleton_method(Hive::Gh, :capture3, ->(*, **) { responses.shift }) do
      error = assert_raises(Hive::GhError) do
        Hive::Gh.digest_pr_diff(repository: "owner/repo", host: "github.com", number: 7)
      end
      assert_match(/gh api.*failed/, error.message)
      assert_includes error.message, "[REDACTED:github_token]"
      refute_includes error.message, secret

      assert_match(/incomplete file pages/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_pr_files(repository: "owner/repo", host: "github.com", number: 7)
      }.message)
      assert_match(/malformed file metadata/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_pr_files(repository: "owner/repo", host: "github.com", number: 7)
      }.message)
      assert_match(/unparseable/, assert_raises(Hive::GhError) {
        Hive::Gh.digest_pr_files(repository: "owner/repo", host: "github.com", number: 7)
      }.message)
    end

    assert_match(/invalid pull-request diff input/, assert_raises(Hive::GhError) {
      Hive::Gh.digest_pr_diff(repository: "owner/repo", host: "github.com", number: Object.new)
    }.message)
    assert_match(/invalid pull-request files input/, assert_raises(Hive::GhError) {
      Hive::Gh.digest_pr_files(repository: "owner/repo", host: "github.com", number: Object.new)
    }.message)
  end

  def test_pr_body_returns_empty_for_missing_file_and_strips_frontmatter
    with_tmp_dir do |dir|
      path = File.join(dir, "pr.md")
      assert_equal "", Hive::Gh.pr_body(path)
      File.write(path, "---\ntitle: Example\n---\n\nBody text\n")
      assert_equal "Body text", Hive::Gh.pr_body(path)
    end
  end

  private

  def row(number, updated_at)
    { "number" => number, "updated_at" => updated_at, "merged_at" => updated_at }
  end
end
