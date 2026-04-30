require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "paths"
require_relative "sandbox"
require_relative "scenario_parser"
require_relative "step_executor"

module Hive
  module E2E
    class Runner
      attr_reader :run_id, :run_dir

      def initialize(scenarios_dir: Paths.scenarios_dir, runs_dir: Paths.runs_dir)
        @scenarios_dir = scenarios_dir
        @runs_dir = runs_dir
        @results = []
      end

      def run_all(pattern: nil, tag: nil, keep_artifacts: false)
        @run_id = generate_run_id
        @run_dir = File.join(@runs_dir, @run_id)
        FileUtils.mkdir_p(File.join(@run_dir, "scenarios"))
        @started_at = Time.now.utc
        scenarios = select_scenarios(pattern: pattern, tag: tag)
        raise "no scenarios match #{pattern || tag || 'all'}" if scenarios.empty?

        write_report(status: "partial", total: scenarios.size)
        scenarios.each do |scenario|
          sandbox = Sandbox.bootstrap(File.join(@run_dir, scenario.name))
          scenario_dir = File.join(@run_dir, "scenarios", scenario.name)
          result = StepExecutor.new(scenario: scenario, sandbox: sandbox, scenario_dir: scenario_dir, run_id: @run_id).execute
          @results << result
          sandbox.cleanup unless keep_artifacts || result.status == "failed"
          write_report(status: "partial", total: scenarios.size)
        end
        write_report(status: "complete", total: scenarios.size)
        report_hash(status: "complete", total: scenarios.size)
      rescue StandardError
        write_report(status: "crashed", total: @results.size)
        raise
      end

      def select_scenarios(pattern: nil, tag: nil)
        files = Dir[File.join(@scenarios_dir, "*.yml")].reject { |path| File.basename(path).start_with?("_") }.sort
        scenarios = files.map { |path| ScenarioParser.parse(path) }
        scenarios = scenarios.select { |scenario| scenario.name.include?(pattern.to_s) || File.basename(scenario.path).include?(pattern.to_s) } if pattern && !pattern.empty?
        scenarios = scenarios.select { |scenario| scenario.tags.include?(tag.to_s) } if tag && !tag.empty?
        scenarios
      end

      private

      def generate_run_id
        "#{Time.now.utc.strftime('%Y-%m-%dT%H-%M-%SZ')}-#{Process.pid}-#{SecureRandom.hex(2)}"
      end

      def write_report(status:, total:)
        path = File.join(@run_dir, "report.json")
        tmp = "#{path}.tmp.#{Process.pid}"
        File.write(tmp, JSON.pretty_generate(report_hash(status: status, total: total)))
        File.rename(tmp, path)
      ensure
        FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
      end

      def report_hash(status:, total:)
        passed = @results.count { |result| result.status == "passed" }
        failed = @results.count { |result| result.status == "failed" }
        {
          "schema" => "hive-e2e-report",
          "schema_version" => 1,
          "run_id" => @run_id,
          "started_at" => @started_at&.iso8601,
          "ended_at" => Time.now.utc.iso8601,
          "status" => status,
          "summary" => {
            "total" => total,
            "passed" => passed,
            "failed" => failed
          },
          "scenarios" => @results.map(&:to_h)
        }
      end
    end
  end
end
