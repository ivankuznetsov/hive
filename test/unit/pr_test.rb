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
end
