# Frozen_string_literal: true

# Single-seed flake-sweep runner: loads the default suite exactly like CI's
# coverage shards do (minus the expensive outer-proof gates), runs it under
# one Minitest seed in a single process, and emits a JSON report with
# per-file durations and per-test failures. The nightly workflow invokes this
# once per seed; script/flake_sweep_report.rb merges the reports into the
# order-dependent-flake candidate list and the shard-timings payload.
#
# Usage: bundle exec ruby script/flake_sweep.rb --seed 1234 --report out.json
#
# ARGV is stripped of this script's flags before the suite starts so the
# remaining "--seed N" reaches Minitest.process_args via at_exit autorun.

report_path = nil
seed = nil
flags = []
argv = ARGV.dup
loop do
  case argv.first
  when "--report"
    argv.shift
    report_path = argv.shift
  when "--seed"
    seed = argv[1]
    flags.concat(argv.shift(2))
  else
    break
  end
end
abort "usage: flake_sweep.rb --seed N --report PATH" unless report_path && seed
ARGV.replace(flags)

root = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(File.join(root, "test"))
$LOAD_PATH.unshift(File.join(root, "lib"))

gate_test_files = [
  "test/integration/web_packaged_bootstrap_test.rb",
  "test/integration/tui_reactivity_perf_test.rb",
  "test/integration/setup_agents_test.rb",
  "test/unit/babysitter/dry_run_security_matrix_test.rb"
]
suite_files = Dir.glob(File.join(root, "test/{unit,integration,babysitter}/**/*_test.rb"))
  .reject { |path| gate_test_files.include?(path.delete_prefix("#{root}/")) }
  .sort

started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
results = []
results_lock = Mutex.new

collector = Object.new
collector.define_singleton_method(:io) { nil }
collector.define_singleton_method(:options=) { |_o| nil }
collector.define_singleton_method(:record) do |result|
  location = begin
    result.source_location
  rescue StandardError
    nil
  end
  file = location&.first&.delete_prefix("#{root}/")
  entry = {
    "identifier" => "#{result.klass}##{result.name}",
    "file" => file,
    "seconds" => result.time,
    "failed" => result.failures.any? && !result.skipped?,
    "skipped" => result.skipped?,
    "message" => result.failures.first&.message
  }
  results_lock.synchronize { results << entry }
end
collector.define_singleton_method(:prerecord) { |*_args| nil }
collector.define_singleton_method(:report) { nil }

Minitest.reporter << collector

at_exit do
  exit_status = $!.is_a?(SystemExit) ? $!.status : ($!.nil? ? 0 : 1)
  per_file = Hash.new(0.0)
  results.each { |entry| per_file[entry["file"]] += entry["seconds"] if entry["file"] }
  report = {
    "schema" => "hive-flake-sweep-run.v1",
    "seed" => Integer(seed),
    "suite_files" => suite_files.length,
    "total_seconds" => Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at,
    "per_file_seconds" => per_file,
    "tests_run" => results.count { |entry| !entry["skipped"] },
    "failures" => results
      .select { |entry| entry["failed"] }
      .map { |entry| entry.slice("identifier", "file", "message") }
  }
  File.write(report_path, JSON.pretty_generate(report))
  warn "flake sweep seed #{seed}: #{report['tests_run']} tests, " \
       "#{report['failures'].length} failures, #{report['total_seconds'].round(1)}s -> #{report_path}"
  exit(exit_status)
end

require "test_helper"
suite_files.each { |path| require path }
