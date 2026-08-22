# Frozen-string-literal comment intentionally omitted: this file appends to
# mutable report strings and never ships constants downstream.

require "json"
require "fileutils"

# Machine-readable failure evidence for CI agents. When the suite fails on a
# hosted runner, this plugin writes a GitHub step summary plus a JSON artifact
# naming every failing test with its Minitest seed and an exact single-test
# repro command, so consumers of `gh run view` skip the log-spelunking phase.
#
# Fail-open contract: evidence emission must never change the suite exit
# status. Every write path rescues StandardError and warns.
module HiveFailureEvidence
  REPRO_PREFIX = "bundle exec ruby -Itest -Ilib"

  class << self
    attr_accessor :summary_path_override, :evidence_path_override
  end

  FailureEntry = Struct.new(
    :test_identifier,
    :file,
    :line,
    :message,
    :seed,
    keyword_init: true,
  ) do
    def self.from_result(result, seed)
      first_failure = result.failures.first
      location = result_source_location(result)
      new(
        test_identifier: "#{result.klass}##{result.name}",
        file: location&.first,
        line: location&.last,
        message: first_failure ? "#{first_failure.class}: #{first_failure.message}" : nil,
        seed: seed,
      )
    end

    def self.result_source_location(result)
      result.source_location
    rescue NoMethodError, StandardError
      nil
    end

    def repro_command
      argv = [ REPRO_PREFIX, file ].compact
      argv << "--seed #{seed}" if seed
      argv << "--name #{test_identifier}" if test_identifier
      argv.join(" ")
    end

    def as_json
      {
        "test" => test_identifier,
        "file" => file,
        "line" => line,
        "message" => message,
        "seed" => seed,
        "repro_command" => repro_command
      }
    end
  end

  class Reporter < Minitest::AbstractReporter
    attr_reader :failures
    attr_reader :seed

    def initialize(options)
      super()
      @options = options
      @seed = options[:seed]
      @failures = []
      @lock = Mutex.new
    end

    def record(result)
      return if result.skipped?
      return unless result.error? || result.failures.any?

      synchronize { @failures << FailureEntry.from_result(result, @seed) }
    end

    def report
      return if @failures.empty?
      return unless ENV["CI"] && ENV["GITHUB_STEP_SUMMARY"]

      safe { File.write(summary_path, summary_text) }
      safe { write_evidence_json }
      safe do
        warn format(
          "hive failure evidence: %d failing test(s); summary=%s evidence=%s",
          @failures.length,
          summary_path,
          evidence_path,
        )
      end
    end

    private

    def synchronize
      @lock.synchronize { yield }
    end

    def safe
      yield
    rescue StandardError => e
      warn "hive failure evidence: emission failed (ignored): #{e.class}: #{e.message}"
    end

    def summary_path
      HiveFailureEvidence.summary_path_override || "#{ENV.fetch('GITHUB_STEP_SUMMARY')}"
    end

    def evidence_path
      HiveFailureEvidence.evidence_path_override || File.join(Dir.pwd, "tmp", "ci-failure-evidence.json")
    end

    def summary_text
      lines = [ "### Failed tests (#{@failures.length})", "" ]
      @failures.each do |failure|
        lines << "- `#{failure.test_identifier}`"
        lines << "  - repro: `#{failure.repro_command}`"
      end
      lines.join("\n") << "\n"
    end

    def write_evidence_json
      FileUtils.mkdir_p(File.dirname(evidence_path))
      payload = {
        "schema" => "hive-ci-failure-evidence/v1",
        "seed" => @seed,
        "failures" => @failures.map(&:as_json)
      }
      File.write(evidence_path, JSON.pretty_generate(payload))
    end
  end

  def self.minitest_plugin_init(options)
    Minitest.reporter << Reporter.new(options)
  end
end
