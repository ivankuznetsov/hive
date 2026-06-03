require "rake/testtask"
require "fileutils"
require "securerandom"
require_relative "test/support/coverage"

# Default suite — everything under test/{unit,integration}. Self-contained,
# uses fake-claude / fake-gh, no network or paid API calls.
Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/{unit,integration,babysitter}/**/*_test.rb"]
  t.warning = false
end

desc "Run the default suite with merged stdlib Coverage reporting and a 100% line threshold"
task :coverage do
  root = File.expand_path(__dir__)
  run_id = "#{Process.pid}-#{SecureRandom.hex(4)}"
  report_path = File.join(root, "coverage", "coverage.json")
  env_keys = %w[HIVE_COVERAGE HIVE_COVERAGE_ROOT HIVE_COVERAGE_RUN_ID RUBYOPT]
  old_env = env_keys.to_h { |key| [ key, ENV[key] ] }

  begin
    # Wipe the entire resultset tree, not just the current run id (which
    # is fresh per invocation and therefore never exists yet). Without this
    # every local `rake coverage` left stale per-run directories behind.
    FileUtils.rm_rf(File.join(root, "coverage", ".resultset"))
    FileUtils.rm_f(report_path)
    ENV["HIVE_COVERAGE"] = "1"
    ENV["HIVE_COVERAGE_ROOT"] = root
    ENV["HIVE_COVERAGE_RUN_ID"] = run_id
    coverage_rubyopt = "-I#{File.join(root, 'test')} -rhive_coverage_boot"
    ENV["RUBYOPT"] = [ coverage_rubyopt, ENV["RUBYOPT"] ].compact.join(" ")

    Rake::Task[:test].invoke
    unless File.exist?(report_path)
      abort "coverage gate aborted: #{report_path} was never written. " \
            "The test suite likely crashed before the Minitest after_run " \
            "hook fired (e.g. SIGKILL on a subprocess) - re-run with " \
            "TESTOPTS=--verbose to surface the failure."
    end
    report = HiveTestCoverage.read_report(report_path)
    abort HiveTestCoverage.failure_message(report) unless HiveTestCoverage.coverage_ok?(report)
  ensure
    old_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end

# Smoke suite — opt-in, runs against real `claude` and a tmp git repo. Costs
# ~$0.25 per invocation (single brainstorm round). Excluded from the default
# suite so CI without a claude binary doesn't try to run it.
#
#   rake smoke               # run the smoke suite (requires real claude on PATH)
#
# Per project CLAUDE.md (Ivan's rule "use real APIs, make real requests"):
# this is the test bed where claude actually gets called.
Rake::TestTask.new(:smoke) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/smoke/**/*_test.rb"]
  t.warning = false
  t.description = "Run live-claude smoke tests (real subprocess; ~$0.25/run)"
end

namespace :e2e do
  Rake::TestTask.new(:lib_test) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList["test/e2e/lib/**/*_test.rb"]
    t.warning = false
    t.description = "Run e2e harness library tests"
  end

  desc "Remove old e2e run artifacts"
  task :clean do
    ruby "bin/hive-e2e", "clean"
  end
end

namespace :test do
  Rake::TestTask.new(:eval) do |t|
    t.libs << "test"
    t.libs << "lib"
    glob = ENV["HIVE_EVAL_SCENARIOS_ONLY"] == "1" ? "test/eval/scenarios/**/*_test.rb" : "test/eval/**/*_test.rb"
    t.test_files = FileList[glob]
    t.warning = false
    t.description = "Run Telegram bot eval harness tests"
  end
end

desc "Run real-subprocess CLI/TUI e2e scenarios"
task :e2e do
  ruby "bin/hive-e2e", "run"
end

task default: :test
