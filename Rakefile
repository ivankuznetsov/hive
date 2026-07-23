require "rake/testtask"
require "fileutils"
require "securerandom"
require_relative "test/support/coverage"

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

# Default local suite. Self-contained, uses fake-claude / fake-gh, and makes no
# network or paid API calls. Expensive outer proofs run only through their
# explicit CI-gate tasks below.
Rake::TestTask.new do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = HIVE_DEFAULT_TEST_FILES
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

# Smoke suite — opt-in, runs against real agent CLIs and tmp homes/repos.
# Some Claude cases cost roughly $0.25 per invocation. Excluded from the
# default suite so CI without authenticated agent binaries does not run it.
#
#   rake smoke               # run the smoke suite (requires explicitly prepared agents)
#
# Per project CLAUDE.md (Ivan's rule "use real APIs, make real requests"):
# this is the test bed where claude actually gets called.
Rake::TestTask.new(:smoke) do |t|
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

  desc "Remove leaked hive test tmp dirs (system tmpdir + legacy ~/Dev/hive-test*.worktrees)"
  task :clean_tmp do
    require "tmpdir"
    # Only sweep the unmistakably hive-owned prefixes the test helpers
    # create (`Dir.mktmpdir("hive-test")` / `"hive-global"` /
    # `"hive-test-wtbase"` and the `*.origin.git` siblings under them).
    # A crashed test or a sibling bare repo can outlive its `ensure`, so
    # this is the manual broom.
    #
    # The `~/Dev/hive-test*.worktrees` glob mops up the legacy real-home
    # leak: before HIVE_WORKTREE_BASE existed, the default worktree root
    # fell back to `~/Dev/<project>.worktrees`, and test projects named
    # `hive-test<...>` seeded thousands of dirs in the developer's real
    # ~/Dev. The `hive-test` prefix cannot match the production
    # `~/Dev/hive.worktrees` root, so it stays untouched.
    globs = [
      File.join(Dir.tmpdir, "hive-test*"),
      File.join(Dir.tmpdir, "hive-global*"),
      File.expand_path("~/Dev/hive-test*.worktrees")
    ]
    stale = globs.flat_map { |glob| Dir.glob(glob) }.uniq
    stale.each { |path| FileUtils.rm_rf(path) }
    puts "Removed #{stale.size} stale hive test dir(s) (#{Dir.tmpdir} + ~/Dev legacy worktree leak)"
  end
end

desc "Run real-subprocess CLI/TUI e2e scenarios"
task :e2e do
  ruby "bin/hive-e2e", "run"
end

task default: :test
