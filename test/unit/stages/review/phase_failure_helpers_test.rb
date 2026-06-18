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

  def test_review_phase_error_summary_at_exact_limit_is_not_truncated
    limit = Hive::Stages::Review::REVIEW_PHASE_ERROR_SUMMARY_MAX
    exact = "a" * limit

    assert_equal exact, Hive::Stages::Review.send(:review_phase_error_summary, exact),
                 "a message exactly at the cap must pass through unchanged (no ellipsis)"
  end

  def test_review_phase_error_summary_blank_collapses_to_nil
    # nil is the value Markers.set relies on (via attrs.compact) to omit message= entirely.
    [ nil, "", "   ", "\n\t " ].each do |blank|
      assert_nil Hive::Stages::Review.send(:review_phase_error_summary, blank),
                 "blank/whitespace error_message (#{blank.inspect}) must yield no message= attr"
    end
  end

  def test_review_phase_error_summary_collapses_internal_whitespace
    assert_equal "line one line two",
                 Hive::Stages::Review.send(:review_phase_error_summary, "line one\n\tline two")
  end

  def test_triage_max_attempts_defaults_when_unset
    assert_equal Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS,
                 Hive::Stages::Review.send(:triage_max_attempts, {})
  end

  def test_triage_max_attempts_honors_explicit_value
    cfg = { "review" => { "triage" => { "max_attempts" => 3 } } }
    assert_equal 3, Hive::Stages::Review.send(:triage_max_attempts, cfg)
  end

  def test_triage_max_attempts_clamps_zero_and_negative_to_one
    [ 0, -3 ].each do |bad|
      cfg = { "review" => { "triage" => { "max_attempts" => bad } } }
      assert_equal 1, Hive::Stages::Review.send(:triage_max_attempts, cfg),
                   "#{bad} must clamp to a single attempt, never run zero/negative times"
    end
  end

  def test_triage_max_attempts_falls_back_on_non_integer_instead_of_raising
    # Config::POSITIVE_INTEGER_KEYS rejects this at load, but programmatic configs
    # bypass validation; the helper must not abort the run with an uncaught error.
    cfg = { "review" => { "triage" => { "max_attempts" => "2.5" } } }
    out = capture_io do
      assert_equal Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS,
                   Hive::Stages::Review.send(:triage_max_attempts, cfg)
    end
    assert_match(/invalid review.triage.max_attempts/, out.join)
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
