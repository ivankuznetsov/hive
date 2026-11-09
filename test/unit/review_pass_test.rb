require "test_helper"
require "hive/review_pass"
require "hive/stages/review/orchestrator_owned"

class ReviewPassTest < Minitest::Test
  def test_numbers_accept_extended_and_zero_padded_suffixes
    assert_equal 100, Hive::ReviewPass.number("/tmp/reviews/codex-native-100.md")
    assert_equal 100, Hive::ReviewPass.number("codex-native-0100.md")
    assert_equal 1, Hive::ReviewPass.number("codex-native-01.md")
    assert_equal "codex-native", Hive::ReviewPass.prefix("codex-native-100.md")
    assert_equal "codex-native", Hive::ReviewPass.prefix("/tmp/reviews/codex-native-0100.md")
  end

  def test_numbers_and_prefixes_reject_non_pass_files
    [ nil, "codex-1.md", "codex-100.json", "codex-100.md.extra", "suppressed.md" ].each do |name|
      assert_nil Hive::ReviewPass.number(name)
      assert_nil Hive::ReviewPass.prefix(name)
    end
  end

  def test_sort_key_orders_passes_numerically_and_reviewer_names_stably
    files = %w[codex-100.md codex-99.md claude-0100.md suppressed.md]

    assert_equal %w[suppressed.md codex-99.md claude-0100.md codex-100.md],
      files.sort_by { |path| Hive::ReviewPass.sort_key(path) }
  end

  def test_budget_receipts_are_recognized_and_excluded_from_reviewer_files
    [ "review-grant-#{'a' * 64}.json", "review-completion-#{'b' * 64}-100.json" ].each do |name|
      assert Hive::ReviewPass.budget_receipt?(name)
      refute Hive::Stages::Review.reviewer_file?(name)
    end
    [ "review-grant-malformed.json", "review-completion-#{'b' * 64}-1.json", "codex-100.md" ].each do |name|
      refute Hive::ReviewPass.budget_receipt?(name)
    end
    refute Hive::Stages::Review.reviewer_file?("fix-success-100.md")
    assert Hive::Stages::Review.reviewer_file?("codex-100.md")
  end
end
