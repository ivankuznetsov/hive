require "test_helper"

module TestFlakeQuarantine
  # Exercises the real prepended retry machinery: a test that fails its first
  # attempt and passes the second must leave the suite green with the retry
  # recorded in the failure-evidence budget; a test that fails its retry must
  # still fail; non-quarantined and empty-list runs must never retry.
  class RetryBehaviorTest < Minitest::Test
    def setup
      @previous_retries = HiveFailureEvidence.retries.dup
      HiveFailureEvidence.retries.clear
    end

    def teardown
      HiveFailureEvidence.retries.replace(@previous_retries)
      HiveFlakeQuarantine.deactivate_for_tests!
    end

    def test_quarantined_test_that_fails_once_then_passes_is_green_with_visible_retry
      flaky = flaky_class("FlakyOnceTest", passes_on_attempt: 2)
      HiveFlakeQuarantine.activate_for_tests!("FlakyOnceTest#test_unstable" => "seed-order evidence (2026-08-21)")

      result = flaky.new(:test_unstable).run

      assert_empty result.failures
      assert_equal 1, HiveFailureEvidence.retries.length
      assert_includes HiveFailureEvidence.retries.first, "FlakyOnceTest#test_unstable retried (attempt 1)"
      assert_includes HiveFailureEvidence.retries.first, "seed-order evidence"
    end

    def test_quarantined_test_that_fails_its_retry_still_fails_the_suite
      flaky = flaky_class("FlakyAlwaysTest", passes_on_attempt: nil)
      HiveFlakeQuarantine.activate_for_tests!("FlakyAlwaysTest#test_unstable" => "seed-order evidence (2026-08-21)")

      result = flaky.new(:test_unstable).run

      refute_empty result.failures
      assert_equal 1, HiveFailureEvidence.retries.length
    ensure
      HiveFailureEvidence.retries.clear
    end

    def test_non_quarantined_test_never_retries_even_when_the_list_is_active
      flaky = flaky_class("UnlistedTest", passes_on_attempt: nil)
      HiveFlakeQuarantine.activate_for_tests!("SomeOtherTest#test_other" => "unrelated")

      result = flaky.new(:test_unstable).run

      refute_empty result.failures
      assert_empty HiveFailureEvidence.retries
    end

    def test_empty_effective_list_disables_all_retries_via_sentinel
      flaky = flaky_class("SentinelTest", passes_on_attempt: nil)
      HiveFlakeQuarantine.activate_for_tests!({})

      result = flaky.new(:test_unstable).run

      refute_empty result.failures
      assert_empty HiveFailureEvidence.retries
    end

    def test_production_list_starts_empty_with_documented_reasons_required
      assert_empty HiveFlakeQuarantine::QUARANTINED_TESTS,
                   "entries land only in a dedicated commit with sweep evidence"
    end

    private

    def flaky_class(class_name, passes_on_attempt:)
      attempts = 0
      Class.new(Minitest::Test) do
        define_singleton_method(:name) { class_name }
        define_method(:test_unstable) do
          attempts += 1
          if passes_on_attempt
            assert_equal passes_on_attempt, attempts, "flaky attempt #{attempts}"
          else
            flunk "always fails (attempt #{attempts})"
          end
        end
      end
    end
  end
end
