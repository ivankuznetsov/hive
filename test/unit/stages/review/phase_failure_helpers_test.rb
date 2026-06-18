require_relative "../../../test_helper"
require "hive/stages/review"

class ReviewPhaseFailureHelpersTest < Minitest::Test
  include HiveTestHelper

  def test_review_phase_error_summary_truncates_long_message
    limit = Hive::Stages::Review::REVIEW_PHASE_ERROR_SUMMARY_MAX
    summary = Hive::Stages::Review.send(:review_phase_error_summary, "a" * (limit + 5))

    assert_equal limit, summary.length
    assert summary.end_with?("\u2026")
    assert_equal "a" * (limit - 1), summary.delete_suffix("\u2026")
  end

  def test_triage_retry_backoff_uses_capped_exponential_delay
    delays = []

    with_replaced_singleton_method(Hive::Stages::Review, :sleep, lambda { |duration|
      delays << duration
    }) do
      Hive::Stages::Review.send(:triage_retry_backoff, 1)
      Hive::Stages::Review.send(:triage_retry_backoff, 10)
    end

    assert_equal [ 1, Hive::Reviewers::REVIEWER_BACKOFF_CAP_SEC ], delays
  end
end
