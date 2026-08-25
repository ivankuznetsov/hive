# Frozen_string_literal: true

# Renders the nightly flake-sweep issue body from a merged candidates report
# (script/flake_sweep_report.rb --candidates). Issue creation/updating and
# dedup happen in the workflow; this only owns the markdown.

require "json"

payload = JSON.parse(File.read(ARGV.fetch(0)))
candidates = payload.fetch("order_dependent_candidates")
consistent = payload.fetch("consistently_failing")

lines = []
lines << "Nightly seed sweep across seeds #{payload.fetch('seeds').inspect} " \
         "(#{payload.fetch('tests_run_per_seed')} tests per seed)."
lines << ""
if candidates.empty? && consistent.empty?
  lines << "**No failures in any seed.** Suite is clean across orderings."
elsif consistent.any?
  lines << "## Consistently failing (fails under every seed — likely a real regression)"
  lines << ""
  consistent.each { |entry| lines << "- `#{entry['test']}` — #{entry['sample_message']}" }
end
unless candidates.empty?
  lines << "" unless lines.empty?
  lines << "## Order-dependent candidates (fail under some seeds, pass under others)"
  lines << ""
  lines << "Confirm each failure signature before proposing any retry or quarantine policy:"
  lines << ""
  candidates.each do |entry|
    lines << "- `#{entry['test']}` (`#{entry['file']}`) — failing seeds #{entry['failing_seeds'].inspect}: #{entry['sample_message']}"
  end
end
lines << ""
lines << "---"
lines << "Timings artifact: the run's `flake-analysis` artifact is evidence for a later reviewed shard-partition change; required CI does not consume it automatically."

puts lines.join("\n")
