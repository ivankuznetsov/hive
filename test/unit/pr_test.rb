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

  def test_valid_http_url_accepts_http_and_https_with_host
    assert Hive::Pr.valid_http_url?("https://github.com/o/r/pull/1")
    assert Hive::Pr.valid_http_url?("http://example.com")
  end

  def test_valid_http_url_rejects_non_http_schemes_and_empty_host
    refute Hive::Pr.valid_http_url?("javascript:alert(1)")
    refute Hive::Pr.valid_http_url?("ftp://example.com")
    refute Hive::Pr.valid_http_url?("https:///no-host")
  end

  # Symmetric with `number`'s `.to_s` tolerance: a nil or non-String input
  # degrades to false rather than raising TypeError out of URI.parse.
  def test_valid_http_url_is_total_for_nil_and_non_string
    refute Hive::Pr.valid_http_url?(nil)
    refute Hive::Pr.valid_http_url?(12_345)
    refute Hive::Pr.valid_http_url?("")
  end
end
