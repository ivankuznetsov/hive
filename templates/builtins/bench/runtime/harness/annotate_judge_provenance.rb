# frozen_string_literal: true

# Adds reasoning-effort provenance to existing results.json artifacts without
# invoking a judge or changing any recorded score.
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

require "json"
require "lib/judge_provenance"

abort("Usage: ruby harness/annotate_judge_provenance.rb RESULTS_JSON...") if ARGV.empty?

ARGV.each do |path|
  document = JSON.parse(File.read(path))
  HiveBench::JudgeProvenance.annotate_document!(document)
  File.write(path, "#{JSON.pretty_generate(document)}\n")
  warn "annotated judge reasoning provenance: #{path}"
end
