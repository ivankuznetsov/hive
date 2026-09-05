require "json"
require "minitest/autorun"

# A worker receipt is independent of its human-readable log. Bind it to the
# original PID so forked test children cannot overwrite the parent's result.
module HiveParallelResult
  OWNER_PID = Process.pid

  # Minitest 6 fails an empty name-filtered process. A partition may legitimately
  # be empty; the parent enforces nonzero runs/assertions across all receipts.
  module EmptyWorker
    def empty_run!(_options)
      true
    end
  end

  class Reporter < Minitest::AbstractReporter
    def initialize(path)
      @path = path
      @owner = OWNER_PID
      @runs = 0
      @assertions = 0
    end

    def record(result)
      return if result.skipped?

      @runs += 1
      @assertions += result.assertions
    end

    def report
      return unless Process.pid == @owner

      File.write(@path, JSON.generate(runs: @runs, assertions: @assertions))
    end
  end

  def self.minitest_plugin_init(_options)
    Minitest.reporter << Reporter.new(ENV.fetch("HIVE_TEST_RESULT"))
  end
end

Minitest.singleton_class.prepend(HiveParallelResult::EmptyWorker)
Minitest.extensions << HiveParallelResult
