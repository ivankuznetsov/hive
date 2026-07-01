require "test_helper"
require "hive/pr"

class PrTest < Minitest::Test
  def test_number_extracts_pull_request_number
    assert_equal "#561", Hive::Pr.number("https://github.com/o/r/pull/561")
    assert_equal "#561", Hive::Pr.number("https://github.com/o/r/pull/561/")
    assert_equal "#561", Hive::Pr.number("https://github.com/o/r/pull/561?plain=1")
    assert_equal "#561", Hive::Pr.number("https://github.com/o/r/pull/561#discussion")
  end

  def test_number_returns_nil_for_missing_or_non_pr_url
    assert_nil Hive::Pr.number(nil)
    assert_nil Hive::Pr.number("")
    assert_nil Hive::Pr.number("https://github.com/o/r/issues/561")
    assert_nil Hive::Pr.number("https://github.com/o/r/pull/not-a-number")
    assert_nil Hive::Pr.number("https://github.com/o/r/pull/561/files")
  end

  def test_identifier_to_number_accepts_bare_number_hash_number_and_pr_url
    assert_equal 197, Hive::Pr.identifier_to_number("197")
    assert_equal 197, Hive::Pr.identifier_to_number("#197")
    assert_equal 197, Hive::Pr.identifier_to_number(" https://github.com/o/r/pull/197 ")
  end

  def test_identifier_to_number_accepts_pr_url_suffixes_supported_by_number
    assert_equal 197, Hive::Pr.identifier_to_number("https://github.com/o/r/pull/197/")
    assert_equal 197, Hive::Pr.identifier_to_number("https://github.com/o/r/pull/197?diff=split")
    assert_equal 197, Hive::Pr.identifier_to_number("https://github.com/o/r/pull/197#discussion")
  end

  def test_identifier_to_number_rejects_junk_and_deeper_pr_urls
    [
      "",
      "abc",
      "-5",
      # Non-positive numbers parse to a 0 that would otherwise become a
      # bogus adhoc-review-pr-0 slug + a doomed `gh pr view 0`.
      "0",
      "#0",
      "00",
      "https://github.com/o/r/pull/0",
      "https://github.com/o/r/pull/197/files"
    ].each do |identifier|
      err = assert_raises(ArgumentError) { Hive::Pr.identifier_to_number(identifier) }

      assert_includes err.message, "invalid PR identifier"
      assert_includes err.message, "PR number"
    end
  end

  def test_valid_http_url_accepts_http_and_https_with_host
    assert Hive::Pr.valid_http_url?("https://github.com/o/r/pull/1")
    assert Hive::Pr.valid_http_url?("http://example.com")
  end

  def test_valid_http_url_rejects_non_http_schemes_and_empty_host
    refute Hive::Pr.valid_http_url?("javascript:alert(1)")
    refute Hive::Pr.valid_http_url?("ftp://example.com")
    refute Hive::Pr.valid_http_url?("https:///no-host")
  end

  def test_valid_http_url_rejects_invalid_uri
    refute Hive::Pr.valid_http_url?("http://[broken")
  end

  # Symmetric with `number`'s `.to_s` tolerance: a nil or non-String input
  # degrades to false rather than raising TypeError out of URI.parse.
  def test_valid_http_url_is_total_for_nil_and_non_string
    refute Hive::Pr.valid_http_url?(nil)
    refute Hive::Pr.valid_http_url?(12_345)
    refute Hive::Pr.valid_http_url?("")
  end
end
