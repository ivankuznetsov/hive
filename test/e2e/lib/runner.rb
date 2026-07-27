require "fileutils"
require "json"
require "securerandom"
require "time"
require_relative "paths"
require_relative "path_safety"
require_relative "sandbox"
require_relative "scenario_parser"
require_relative "schemas"
require_relative "step_executor"
require_relative "../../../lib/hive/atomic_file"

module Hive
  module E2E
    class Runner
      attr_reader :run_id, :run_dir

      def initialize(scenarios_dir: Paths.scenarios_dir, runs_dir: Paths.runs_dir)
        @scenarios_dir = scenarios_dir
        @runs_dir = runs_dir
        @results = []
        @scenario_metadata = []
      end

      def run_all(pattern: nil, tag: nil, scenarios: nil, keep_artifacts: false, selection: nil)
        @run_id = generate_run_id
        @run_dir = File.join(@runs_dir, @run_id)
        FileUtils.mkdir_p(File.join(@run_dir, "scenarios"))
        write_selection(selection) if selection
        @started_at = Time.now.utc
        @harness_errors = []
        selected_scenarios = scenarios || select_scenarios(pattern: pattern, tag: tag)
        raise "no scenarios match #{pattern || tag || 'all'}" if selected_scenarios.empty?

        @scenario_metadata = selected_scenarios.map { |scenario| scenario_metadata(scenario) }
        runnable_scenarios = selected_scenarios.reject(&:pending)

        # Capture total once so signal handlers and the rescue branch can write
        # a coherent report regardless of how many scenarios actually ran.
        @total = runnable_scenarios.size
        prev_int = Signal.trap("INT") { handle_signal!("INT") }
        prev_term = Signal.trap("TERM") { handle_signal!("TERM") }
        begin
          write_report(status: "partial", total: @total)
          runnable_scenarios.each do |scenario|
            run_one(scenario, keep_artifacts: keep_artifacts)
            write_report(status: "partial", total: @total)
          end
          write_report(status: "complete", total: @total)
          report_hash(status: "complete", total: @total)
        ensure
          Signal.trap("INT", prev_int) if prev_int
          Signal.trap("TERM", prev_term) if prev_term
        end
      rescue StandardError
        write_report(status: "crashed", total: @total || @results.size)
        raise
      end

      def select_scenarios(pattern: nil, tag: nil)
        files = Dir[File.join(@scenarios_dir, "*.yml")].reject { |path| File.basename(path).start_with?("_") }.sort
        scenarios = files.map { |path| ScenarioParser.parse(path) }
        scenarios = scenarios.select { |scenario| scenario.name.include?(pattern.to_s) || File.basename(scenario.path).include?(pattern.to_s) } if pattern && !pattern.empty?
        scenarios = scenarios.select { |scenario| scenario.tags.include?(tag.to_s) } if tag && !tag.empty?
        duplicate = scenarios.group_by(&:name).find { |_name, matches| matches.size > 1 }
        if duplicate
          name, matches = duplicate
          raise ScenarioParser::InvalidScenario.new(
            path: matches.fetch(1).path, line: 1,
            reason: "duplicate scenario name #{name.inspect}; already declared in #{matches.first.path}"
          )
        end
        scenarios
      end

      private

      # Runs a single scenario including bootstrap. Bootstrap failures yield a
      # `setup_failed` per-scenario status so aggregate run status (complete /
      # partial / crashed) is unaffected — agents still see one row per
      # scenario, just with no artifacts_dir / failed_step_index.
      def run_one(scenario, keep_artifacts:)
        started = monotonic_time
        name = PathSafety.safe_basename!(scenario.name, "scenario name")
        scenario_run_dir = direct_child_path(@run_dir, name, "scenario run dir")
        sandbox = Sandbox.bootstrap(scenario_run_dir)
      rescue StandardError => e
        @results << StepExecutor::ScenarioResult.new(
          name: scenario.name, status: "setup_failed", duration_seconds: elapsed_seconds(started),
          failed_step_index: nil, failed_step_kind: nil,
          error_summary: "#{e.class}: #{e.message}",
          artifacts_dir: nil, repro: nil
        )
      else
        scenario_root = direct_child_path(@run_dir, "scenarios", "scenario artifact root")
        scenario_dir = direct_child_path(scenario_root, name, "scenario artifact dir")
        result = StepExecutor.new(scenario: scenario, sandbox: sandbox, scenario_dir: scenario_dir, run_id: @run_id).execute
        if (mutation_error = sample_project_mutation_error)
          @harness_errors << { "kind" => "sample_project_mutated", "message" => mutation_error.message }
          result = failed_harness_result(result, mutation_error)
        end
        result = result.with(duration_seconds: elapsed_seconds(started))
        @results << result
        sandbox.cleanup unless keep_artifacts || result.status == "failed"
      end

      def generate_run_id
        "#{Time.now.utc.strftime('%Y-%m-%dT%H-%M-%SZ')}-#{Process.pid}-#{SecureRandom.hex(2)}"
      end

      def elapsed_seconds(started)
        (monotonic_time - started).round(3)
      end

      def monotonic_time
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def scenario_metadata(scenario)
        {
          "name" => scenario.name,
          "description" => scenario.description,
          "tags" => scenario.tags,
          "incident_id" => scenario.incident_id,
          "sibling_task_id" => scenario.sibling_task_id,
          "pending" => scenario.pending
        }
      end

      def direct_child_path(root, child, label)
        child = PathSafety.safe_basename!(child, label)
        path = PathSafety.contained_path!(root, child, label)
        raise ArgumentError, "#{label} #{path.inspect} must be directly under #{File.expand_path(root).inspect}" unless File.dirname(path) == File.expand_path(root)

        path
      end

      # Flush a "crashed" report and exit with the conventional 128+signum code so
      # CI surfaces interrupted runs distinctly from clean failures.
      def handle_signal!(sig)
        write_report(status: "crashed", total: @total || @results.size)
        begin
          Sandbox.cleanup_runs
        rescue StandardError
          nil
        end
        exit(sig == "INT" ? 130 : 143)
      end

      def sample_project_mutation_error
        Sandbox.new(@run_dir).assert_sample_project_unmutated!
        nil
      rescue StandardError => e
        e
      end

      def failed_harness_result(result, error)
        StepExecutor::ScenarioResult.new(
          name: result.name,
          status: "failed",
          duration_seconds: result.duration_seconds,
          failed_step_index: result.failed_step_index,
          failed_step_kind: result.failed_step_kind || "harness",
          error_summary: "#{error.class}: #{error.message}",
          artifacts_dir: result.artifacts_dir,
          repro: result.repro
        )
      end

      def write_report(status:, total:)
        write_json(
          File.join(@run_dir, "report.json"),
          report_hash(status: status, total: total)
        )
      end

      def write_selection(selection)
        write_json(File.join(@run_dir, "selection.json"), selection)
      end

      def write_json(path, payload)
        Hive::AtomicFile.write(path, JSON.pretty_generate(payload), fsync: false)
      end

      def report_hash(status:, total:)
        passed = @results.count { |result| result.status == "passed" }
        failed = @results.count { |result| result.status == "failed" }
        setup_failed = @results.count { |result| result.status == "setup_failed" }
        {
          "schema" => "hive-e2e-report",
          "schema_version" => Hive::E2E::Schemas.version_for("hive-e2e-report"),
          "run_id" => @run_id,
          "started_at" => @started_at&.iso8601,
          "ended_at" => Time.now.utc.iso8601,
          "status" => status,
          "summary" => {
            "total" => total,
            "passed" => passed,
            "failed" => failed,
            "setup_failed" => setup_failed
          },
          "scenarios" => @results.map(&:to_h),
          "scenario_metadata" => @scenario_metadata || [],
          "harness_errors" => @harness_errors || []
        }
      end
    end
  end
end
