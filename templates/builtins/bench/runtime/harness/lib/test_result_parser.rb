# frozen_string_literal: true

module HiveBench
  # Parses a test run's output into an overall verdict plus a per-test pass map,
  # so the gate (U4 tier 1) can check that the task's FAIL_TO_PASS tests flipped
  # and its PASS_TO_PASS tests stayed green — the SWE-bench objective floor.
  #
  # v1 targets the Ruby/minitest corpus. A parser is intentionally per-framework
  # (SWE-bench learned the same): named-test extraction is framework-specific, so
  # this is the minitest/rake adapter; other frameworks get their own adapter as
  # the corpus widens. When named tests can't be extracted, `by_name` is empty
  # and the gate falls back to the suite-level pass/fail signal.
  module TestResultParser
    module_function

    Result = Data.define(:ran, :passed, :failed, :errored, :by_name) do
      def suite_green? = ran && failed.zero? && errored.zero?
    end

    # Minitest summary line, e.g. "12 runs, 34 assertions, 1 failures, 0 errors, 0 skips".
    SUMMARY = /(\d+)\s+runs?,\s+\d+\s+assertions?,\s+(\d+)\s+failures?,\s+(\d+)\s+errors?/

    # Per-failure header minitest prints, e.g. "  1) Failure:\nFooTest#test_bar".
    FAILURE_BLOCK = /^\s*\d+\)\s+(?:Failure|Error):\s*\n\s*([A-Za-z0-9_:]+#[A-Za-z0-9_?!]+)/

    # Verbose per-test line (TESTOPTS=-v), e.g. "FooTest#test_bar = 0.01 s = .".
    # This is the POSITIVE observation channel: a gate test must appear here (or
    # in a failure block) to count as run at all — absence is never a pass.
    VERBOSE_LINE = /^([A-Za-z0-9_:]+#[A-Za-z0-9_?!]+)\s*=\s*[\d.]+\s*s\s*=\s*([.FES])\s*$/

    def parse(output)
      text = output.to_s
      m = text.match(SUMMARY)
      unless m
        # No recognizable summary — treat as not-run so the gate doesn't read a
        # green verdict out of unparseable noise.
        return Result.new(ran: false, passed: 0, failed: 0, errored: 0, by_name: {})
      end

      runs = m[1].to_i
      failures = m[2].to_i
      errors = m[3].to_i
      by_name = {}
      # Verbose lines first ("." passed; F/E/S did not), then failure blocks —
      # a name in a failure block is false even if its verbose line said ".".
      text.scan(VERBOSE_LINE) { |name, mark| by_name[name] = (mark == ".") }
      text.scan(FAILURE_BLOCK).flatten.each { |n| by_name[n] = false }

      Result.new(ran: true, passed: runs - failures - errors, failed: failures,
                 errored: errors, by_name: by_name)
    end

    # Was this named test positively observed (verbose line or failure block)?
    # The gate requires this for every declared gate test: a test that never ran
    # (typo, deleted, not collected) must never be scored as a pass.
    def observed?(result, name)
      result.ran && result.by_name.key?(name)
    end

    # Did a specific named test pass? Known failures are recorded false; a name
    # not in the failure list is treated as passed when the suite ran. Returns
    # nil when we have no per-name signal at all (caller falls back to suite-level).
    # NOTE: the gate must guard with `observed?` first — the implicit-true branch
    # exists only for suites without verbose output, which are not gate-eligible.
    def test_outcome(result, name)
      return nil unless result.ran

      result.by_name.fetch(name, true)
    end
  end
end
