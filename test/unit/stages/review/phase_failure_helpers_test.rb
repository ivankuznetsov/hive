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

  def test_triage_max_attempts_falls_back_on_infinity_or_nan_instead_of_raising
    # Integer(Float::INFINITY) / Integer(Float::NAN) raise FloatDomainError — a
    # RangeError, NOT an ArgumentError/TypeError — so a programmatic config of
    # those values must still fall back to the default rather than escaping the
    # rescue and aborting the whole 6-review run with a runner_exception.
    [ Float::INFINITY, Float::NAN ].each do |bad|
      cfg = { "review" => { "triage" => { "max_attempts" => bad } } }
      out = capture_io do
        assert_equal Hive::Reviewers::DEFAULT_REVIEWER_MAX_ATTEMPTS,
                     Hive::Stages::Review.send(:triage_max_attempts, cfg),
                     "#{bad} must fall back to the default, not raise FloatDomainError"
      end
      assert_match(/invalid review.triage.max_attempts/, out.join)
    end
  end

  def test_run_triage_with_retries_bails_when_wall_clock_exceeded_between_attempts
    # A transient :error with attempts left, but the review wall-clock budget is
    # spent → don't start another ~1800s triage spawn; signal the caller to
    # finalize REVIEW_STALE reason=wall_clock.
    error = Hive::Stages::Review::Triage::Result.new(
      status: :error, escalations_path: nil, error_message: "transient boom",
      tampered_files: [], limit_text: nil
    )
    with_replaced_singleton_method(Hive::Stages::Review, :mark_working, ->(*) { }) do
      with_replaced_singleton_method(Hive::Stages::Review, :triage_retry_backoff, ->(*) { }) do
        with_replaced_singleton_method(Hive::Stages::Review, :wall_clock_exceeded?, ->(*) { true }) do
          with_replaced_singleton_method(Hive::Stages::Review::Triage, :run!, ->(cfg:, ctx:) { error }) do
            result = Hive::Stages::Review.send(
              :run_triage_with_retries, {}, nil, :task,
              pass: 1, started_at: Time.now, max_wall_clock_sec: 100
            )
            assert_equal :wall_clock_exceeded, result
          end
        end
      end
    end
  end

  def test_run_triage_with_retries_returns_immediately_on_limit_text
    error = Hive::Stages::Review::Triage::Result.new(
      status: :error, escalations_path: nil,
      error_message: "limits reached for claude: Claude Code v2.1.170",
      tampered_files: [], limit_text: "You've hit your session limit"
    )
    calls = 0

    with_replaced_singleton_method(Hive::Stages::Review, :mark_working, ->(*) { }) do
      with_replaced_singleton_method(Hive::Stages::Review, :triage_retry_backoff, ->(*) { flunk "limit must not retry" }) do
        with_replaced_singleton_method(Hive::Stages::Review::Triage, :run!, lambda { |cfg:, ctx:|
          calls += 1
          error
        }) do
          result = Hive::Stages::Review.send(
            :run_triage_with_retries,
            { "review" => { "triage" => { "max_attempts" => 3 } } },
            nil, :task,
            pass: 1, started_at: Time.now, max_wall_clock_sec: 100
          )

          assert_equal error, result
          assert_equal 1, calls
        end
      end
    end
  end

  def test_mark_review_phase_failure_uses_limit_text_for_lossy_messages
    with_tmp_dir do |dir|
      state_file = File.join(dir, "task.md")
      File.write(state_file, "# task\n")
      task = Struct.new(:state_file).new(state_file)

      limited = Hive::Stages::Review.send(
        :mark_review_phase_failure,
        task,
        phase: :triage,
        pass: 1,
        error_message: "limits reached for claude: Claude Code v2.1.170",
        limit_text: "You've hit your session limit"
      )

      marker = Hive::Markers.current(state_file)
      assert limited
      assert_equal :review_error, marker.name
      assert_equal "limits_reached", marker.attrs.fetch("reason")
      assert_equal "triage hit a usage/credit limit", marker.attrs.fetch("message")
      refute_nil marker.attrs["retry_after"]
    end
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
