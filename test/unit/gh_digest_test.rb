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

  private

  def row(number, updated_at)
    { "number" => number, "updated_at" => updated_at, "merged_at" => updated_at }
  end
end
