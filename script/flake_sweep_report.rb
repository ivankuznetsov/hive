# Frozen_string_literal: true

# Merges per-seed flake-sweep reports (script/flake_sweep.rb) into:
#  - an order-dependent-flake candidate list: tests failing in at least one
#    seed but not all (a test failing everywhere is a real regression, not a
#    seed-order flake);
#  - a shard-timings payload keyed by test file, retained as evidence for a
#    later reviewed partition change.
#
# Usage:
#   bundle exec ruby script/flake_sweep_report.rb --reports 'r1.json,r2.json' \
#     --expected-seeds '101,202,303' --candidates candidates.json --timings timings.json

require "digest"
require "json"

reports = []
expected_seeds = nil
candidates_path = nil
timings_path = nil
argv = ARGV.dup
until argv.empty?
  case argv.first
  when "--reports"
    argv.shift
    reports = argv.shift.split(",").map { |path| JSON.parse(File.read(path)) }
  when "--expected-seeds"
    argv.shift
    expected_seeds = argv.shift.split(",").map { |seed| Integer(seed) }
  when "--candidates"
    argv.shift
    candidates_path = argv.shift
  when "--timings"
    argv.shift
    timings_path = argv.shift
  else
    abort "unknown argument: #{argv.first.inspect}"
  end
end
abort "--expected-seeds is required" unless expected_seeds&.any?
abort "expected seeds must be unique" unless expected_seeds.uniq.length == expected_seeds.length

reports.each do |report|
  abort "unsupported sweep report schema: #{report['schema'].inspect}" unless report["schema"] == "hive-flake-sweep-run.v1"

  files = report["suite_files"]
  abort "sweep report suite_files must be a non-empty array" unless files.is_a?(Array) && files.any?
  expected_manifest = Digest::SHA256.hexdigest(files.join("\0"))
  unless report["suite_manifest_sha256"] == expected_manifest
    abort "sweep report suite manifest digest does not match its files"
  end
  abort "sweep report did not finish loading its suite" unless report["suite_loaded"] == true
end

seeds = reports.map { |report| report.fetch("seed") }
if seeds.uniq.length != seeds.length
  abort "duplicate sweep report seeds: #{seeds.tally.select { |_seed, count| count > 1 }.keys.sort.join(',')}"
end
unless seeds.sort == expected_seeds.sort
  abort "expected seeds #{expected_seeds.join(',')}; received #{seeds.sort.join(',')}"
end

suite_manifests = reports.map { |report| report.fetch("suite_manifest_sha256") }.uniq
suite_file_sets = reports.map { |report| report.fetch("suite_files") }.uniq
unless suite_manifests.length == 1 && suite_file_sets.length == 1
  abort "sweep reports do not share one suite manifest"
end

tests_run_per_seed = reports.map { |report| Integer(report.fetch("tests_run")) }
abort "sweep report ran no tests" unless tests_run_per_seed.all?(&:positive?)
unless tests_run_per_seed.uniq.length == 1
  abort "sweep reports disagree on tests_run: #{tests_run_per_seed.inspect}"
end

reports.sort_by! { |report| expected_seeds.index(report.fetch("seed")) }
seeds = reports.map { |report| report.fetch("seed") }
failures_by_test = Hash.new { |hash, key| hash[key] = [] }
per_file_totals = Hash.new(0.0)

reports.each do |report|
  report.fetch("failures").each do |failure|
    failures_by_test[failure.fetch("identifier")] <<
      { "seed" => report.fetch("seed"), "file" => failure["file"], "message" => failure["message"] }
  end
  report.fetch("per_file_seconds").each do |file, seconds|
    per_file_totals[file] += Float(seconds)
  end
end

order_dependent, consistently_failing = failures_by_test
  .partition { |_identifier, occurrences| occurrences.length < seeds.length }
  .map(&:to_h)

payload = {
  "schema" => "hive-flake-sweep-report.v1",
  "seeds" => seeds,
  "tests_run_per_seed" => tests_run_per_seed,
  "order_dependent_candidates" => order_dependent.map do |identifier, occurrences|
    {
      "test" => identifier,
      "failing_seeds" => occurrences.map { |occurrence| occurrence["seed"] },
      "sample_message" => occurrences.first["message"]&.lines&.first&.strip,
      "file" => occurrences.first["file"]
    }
  end,
  "consistently_failing" => consistently_failing.map do |identifier, occurrences|
    {
      "test" => identifier,
      "failing_seeds" => occurrences.map { |occurrence| occurrence["seed"] },
      "sample_message" => occurrences.first["message"]&.lines&.first&.strip
    }
  end
}

if candidates_path
  File.write(candidates_path, JSON.pretty_generate(payload))
  warn "flake sweep: #{payload['order_dependent_candidates'].length} order-dependent candidate(s), " \
       "#{payload['consistently_failing'].length} consistently failing -> #{candidates_path}"
end

if timings_path
  timings = {
    "schema" => "hive-shard-timings.v1",
    "seeds" => seeds,
    "seconds_per_run" => per_file_totals.transform_values { |total| (total / seeds.length).round(4) }
  }
  File.write(timings_path, JSON.pretty_generate(timings))
  warn "flake sweep: per-file mean timings for #{timings['seconds_per_run'].length} files -> #{timings_path}"
end

exit(payload["consistently_failing"].empty? ? 0 : 1)
