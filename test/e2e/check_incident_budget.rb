#!/usr/bin/env ruby

require "json"
require_relative "lib/incident_budget"

input = ARGV.fetch(0) do
  abort "usage: #{$PROGRAM_NAME} REPORT_JSON_OR_RUNS_DIR"
end

report_path = if File.file?(input)
  input
else
  Dir[File.join(input, "*", "report.json")].max_by { |path| File.mtime(path) }
end
abort "no e2e report found under #{input}" unless report_path

checked = Hive::E2E::IncidentBudget.check(JSON.parse(File.read(report_path)))
checked.durations.sort.each do |name, duration|
  puts format("%s: %.3fs", name, duration)
end
puts format("incident total: %.3fs", checked.total_seconds)

unless checked.ok?
  checked.violations.each { |violation| warn "incident budget: #{violation}" }
  exit 1
end
