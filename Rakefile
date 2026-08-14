require "rake/testtask"
require "fileutils"
require "securerandom"
require_relative "test/support/coverage"
require_relative "test/support/tmp_cleanup"

# These expensive outer proofs are intentionally separate from the normal local
# suite. CI runs them as named merge gates.
HIVE_CI_GATE_TESTS = {
  "test:packaged_web_bootstrap" => "test/integration/web_packaged_bootstrap_test.rb",
  "test:tui_reactivity_perf" => "test/integration/tui_reactivity_perf_test.rb",
  "test:setup_agents_integration" => "test/integration/setup_agents_test.rb",
  "test:babysitter_dry_run_security_matrix" =>
    "test/unit/babysitter/dry_run_security_matrix_test.rb"
}.freeze
HIVE_CI_GATE_TEST_OPTIONS = {
  "test:babysitter_dry_run_security_matrix" =>
    "--include=test_stubs_skip_unknown_and_mutating_commands_but_allow_read_only_commands"
}.freeze
HIVE_DEFAULT_TEST_FILES = FileList[
  "test/{unit,integration,babysitter}/**/*_test.rb"
].exclude(*HIVE_CI_GATE_TESTS.values).to_a.freeze
HIVE_COVERAGE_SHARD_COUNT = 6
HIVE_COVERAGE_SHARDS = begin
  partition_by_bytes = lambda do |files, count|
    shards = Array.new(count) { [] }
    shard_bytes = Array.new(count, 0)

    files.sort_by { |path| [ -File.size(path), path ] }.each do |path|
      shard = shard_bytes.each_index.min_by { |index| [ shard_bytes[index], index ] }
      shards.fetch(shard) << path
      shard_bytes[shard] += File.size(path)
    end

    shards
  end

  # Hosted runs identified the third source-balanced partition as the original
  # long pole, then exposed the fourth as the remaining long pole. Split those
  # measured hot partitions while preserving the two faster partitions and
  # adding only two runners instead of reshuffling or doubling the whole matrix.
  base_shards = partition_by_bytes.call(HIVE_DEFAULT_TEST_FILES, 4)
  hot_shards = partition_by_bytes.call(base_shards.fetch(2), 2)
  tail_shards = partition_by_bytes.call(base_shards.fetch(3), 2)
  shards = [ base_shards[0], base_shards[1], *hot_shards, *tail_shards ]
  shards.each(&:freeze)
  shards.freeze
end
HIVE_HOSTILE_TEST_FILES = FileList[
  "test/unit/packaging/workflow_creator_values_test.rb",
  "test/unit/packaging/patrol_evidence_candidate_test.rb",
  "test/unit/packaging/patrol_evidence_sandbox_test.rb"
].to_a.freeze

# Default local suite. Self-contained, uses fake-claude / fake-gh, and makes no
# network or paid API calls. Expensive outer proofs run only through their
# explicit CI-gate tasks below.
Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = HIVE_DEFAULT_TEST_FILES
  t.warning = false
end

Rake::TestTask.new("test:agent_cli_runtime") do |t|
  t.libs << "components/agent-cli-runtime/test"
  t.libs << "components/agent-cli-runtime/lib"
  t.test_files = FileList["components/agent-cli-runtime/test/**/*_test.rb"]
  t.warning = false
  t.description = "Run the standalone Agent CLI Runtime package tests"
end

Rake::Task[:test].enhance([ "test:agent_cli_runtime" ])

task "test:enable_hostile" do
  ENV["HIVE_HOSTILE_TESTS"] = "1"
end

Rake::TestTask.new("test:hostile" => "test:enable_hostile") do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = HIVE_HOSTILE_TEST_FILES
  t.warning = false
  t.description = "Run opt-in hostile/property campaigns outside default CI"
end

desc "Run the default suite with merged stdlib Coverage reporting and a 100% line threshold"
task :coverage do
  root = File.expand_path(__dir__)
  run_id = ENV.fetch("HIVE_COVERAGE_RUN_ID") { "#{Process.pid}-#{SecureRandom.hex(4)}" }
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

namespace :coverage do
  coverage_shard_index = Integer(ENV["HIVE_COVERAGE_SHARD_INDEX"], exception: false)
  coverage_shard_files = coverage_shard_index ? HIVE_COVERAGE_SHARDS.fetch(coverage_shard_index, []) : []

  task :prepare_shard do
    shard_index = Integer(ENV.fetch("HIVE_COVERAGE_SHARD_INDEX"))
    shard_count = Integer(ENV.fetch("HIVE_COVERAGE_SHARD_COUNT"))
    unless shard_count == HIVE_COVERAGE_SHARD_COUNT && shard_index.between?(0, shard_count - 1)
      abort "coverage shard must be 0..#{HIVE_COVERAGE_SHARD_COUNT - 1} " \
            "of #{HIVE_COVERAGE_SHARD_COUNT}"
    end

    root = File.expand_path(__dir__)
    run_id = ENV.fetch("HIVE_COVERAGE_RUN_ID")
    abort "HIVE_COVERAGE_RUN_ID must not be empty" if run_id.empty?

    FileUtils.rm_rf(File.join(root, "coverage", ".resultset"))
    FileUtils.rm_f(File.join(root, "coverage", "coverage.json"))
    ENV["HIVE_COVERAGE"] = "1"
    ENV["HIVE_COVERAGE_ROOT"] = root
    ENV["HIVE_COVERAGE_COLLECT_ONLY"] = "1"
    ENV["HIVE_COVERAGE_LOAD_ALL"] = shard_index.zero? ? "1" : "0"
    ENV["HIVE_REQUIRE_TEST_RUNS"] = "1"
    coverage_rubyopt = "-I#{File.join(root, 'test')} -rhive_coverage_boot"
    ENV["RUBYOPT"] = [ coverage_rubyopt, ENV["RUBYOPT"] ].compact.join(" ")
  rescue ArgumentError, KeyError
    abort "coverage shard index, count, and run ID must be provided"
  end

  Rake::TestTask.new(run_shard: :prepare_shard) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = coverage_shard_files
    t.warning = false
  end
  Rake::Task["coverage:run_shard"].enhance([ "test:agent_cli_runtime" ]) if coverage_shard_index == 0

  desc "Collect one deterministic CI coverage shard without applying the final percentage gate"
  task collect: :run_shard do
    run_id = ENV.fetch("HIVE_COVERAGE_RUN_ID")
    resultset_dir = File.join(__dir__, "coverage", ".resultset", run_id)
    process_results = Dir.glob(File.join(resultset_dir, "*.marshal"))
    dump_errors = Dir.glob(File.join(resultset_dir, "*.error.json"))
    abort "coverage shard wrote no process results to #{resultset_dir}" if process_results.empty?
    abort "coverage shard recorded dump errors in #{resultset_dir}" if dump_errors.any?

    puts "Collected #{process_results.length} coverage process result(s) for #{run_id}"
  end

  desc "Merge previously collected CI coverage artifacts and apply the exact coverage gate"
  task :report do
    root = File.expand_path(__dir__)
    report_path = File.join(root, "coverage", "coverage.json")
    HiveTestCoverage.configure!(root: root)
    HiveTestCoverage.report!
    report = HiveTestCoverage.read_report(report_path)
    abort HiveTestCoverage.failure_message(report) unless HiveTestCoverage.coverage_ok?(report)
  end
end

# Smoke suite — opt-in, runs against real agent CLIs and tmp homes/repos.
# Some Claude cases cost roughly $0.25 per invocation. Excluded from the
# default suite so CI without authenticated agent binaries does not run it.
#
#   rake smoke               # run the smoke suite (requires explicitly prepared agents)
#
# Per project CLAUDE.md (Ivan's rule "use real APIs, make real requests"):
# this is the test bed where claude actually gets called.
task "test:allow_real_user_environment" do
  ENV["HIVE_TEST_ALLOW_REAL_USER_ENV"] = "1"
end

Rake::TestTask.new(smoke: "test:allow_real_user_environment") do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/smoke/**/*_test.rb"]
  t.warning = false
  t.description = "Run authenticated live-agent smoke tests (real subprocesses; may incur API cost)"
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

  Rake::TestTask.new(:patrol_qualification_reduced) do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList[
      "test/e2e/qualification/patrol_qualification_test.rb"
    ]
    t.warning = false
    t.description = "Run the opt-in reduced installed-CLI Patrol qualification smoke"
  end
end

task "test:require_nonempty_ci_gate" do
  ENV["HIVE_REQUIRE_TEST_RUNS"] = "1"
end

HIVE_CI_GATE_TESTS.each do |qualified_name, test_file|
  Rake::TestTask.new(qualified_name => "test:require_nonempty_ci_gate") do |t|
    t.libs << "test"
    t.libs << "lib"
    t.test_files = FileList[test_file]
    t.options = HIVE_CI_GATE_TEST_OPTIONS[qualified_name]
    t.warning = false
    t.description = "Run the #{qualified_name.delete_prefix("test:").tr("_", " ")} merge gate"
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

  desc "Remove stale, inactive Hive test tmp dirs"
  task :clean_tmp do
    min_age_seconds = Integer(
      ENV.fetch("HIVE_TEST_TMP_MIN_AGE_SECONDS", HiveTestTmpCleanup::DEFAULT_MIN_AGE_SECONDS.to_s),
      10
    )
    result = HiveTestTmpCleanup.sweep(min_age_seconds: min_age_seconds)

    puts "Removed #{result.removed.size} stale Hive test dir(s); " \
         "skipped #{result.skipped_live.size} live, " \
         "#{result.skipped_recent.size} recent, and " \
         "#{result.skipped_unowned.size} unowned"

    next if result.failed.empty?

    result.failed.each { |failure| warn "Cleanup failed for #{failure.fetch(:path)}: #{failure.fetch(:error)}" }
    raise "Failed to remove #{result.failed.size} stale Hive test dir(s)"
  end
end

desc "Run real-subprocess CLI/TUI e2e scenarios"
task :e2e do
  ruby "bin/hive-e2e", "run"
end

task default: :test
