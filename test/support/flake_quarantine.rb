# Frozen_string_literal: true

# Explicit quarantine list for known-flaky tests. A quarantined test gets
# exactly one in-process retry (via minitest-retry) inside the same suite
# run; every retry is loudly logged and recorded in the CI failure-evidence
# summary so the retry rate stays a tracked budget instead of silent noise.
# A test that fails its retry still fails the suite.
#
# Entries are added only with sweep or CI evidence and carry a reason and
# date. Removing an entry should follow a green seed sweep for that test.
module HiveFlakeQuarantine
  NEVER_MATCH = "__hive_flake_quarantine_disabled__"

  # "TestClass#test_name" => "reason (added YYYY-MM-DD)"
  QUARANTINED_TESTS = {}.freeze

  class << self
    def quarantined?(test_identifier)
      effective_list.key?(test_identifier)
    end

    def reason_for(test_identifier)
      effective_list.fetch(test_identifier, "quarantined")
    end

    def empty?
      QUARANTINED_TESTS.empty?
    end

    # Activates (or refreshes) the retry machinery against the current
    # effective list. Safe to call repeatedly: prepending is idempotent and
    # each call resets the module's retry configuration and callbacks. An
    # empty list passes a never-matching sentinel because minitest-retry's
    # empty `methods_to_retry` means "retry every failure".
    def activate!
      return false unless retry_gem_available?

      list = effective_list
      Minitest::Retry.use!(
        retry_count: 1,
        io: $stdout,
        verbose: true,
        methods_to_retry: list.any? ? list.keys : [ NEVER_MATCH ],
      )
      Minitest::Retry.on_retry do |klass, method_name, attempt, _result|
        identifier = "#{klass.name}##{method_name}"
        next unless quarantined?(identifier)

        HiveFailureEvidence.retries <<
          "#{identifier} retried (attempt #{attempt}) — #{reason_for(identifier)}"
      end
      true
    end

    # Test-only override layer: lets focused tests exercise the retry path
    # without touching the frozen production list. Deactivate restores the
    # production list and reactivates.
    def activate_for_tests!(override_list)
      @test_override = override_list
      activate!
    end

    def deactivate_for_tests!
      @test_override = nil
      activate!
    end

    private

    # Bundler-managed runs (CI, `bundle exec`) must have the gem, so a
    # LoadError there is a real failure. A plain `ruby -Itest` run without an
    # installed bundle degrades to "no retries" instead of failing every
    # suite at load time.
    def retry_gem_available?
      return @retry_gem_available unless @retry_gem_available.nil?

      @retry_gem_available = begin
        require "minitest/retry"
        true
      rescue LoadError
        raise if defined?(Bundler)

        warn "minitest-retry unavailable; flake-quarantine retries disabled for this run"
        false
      end
    end

    def effective_list
      @test_override || QUARANTINED_TESTS
    end
  end
end
