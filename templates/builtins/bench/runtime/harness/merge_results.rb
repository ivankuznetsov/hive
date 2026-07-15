# frozen_string_literal: true

# Make the harness dir importable when run directly (`ruby harness/merge_results.rb`).
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

require "json"
require "score"

module HiveBench
  # Combines several per-agent results.json files (each from a separate `run_all`
  # pass) into ONE leaderboard results.json: unions their cells, re-aggregates the
  # per-agent summaries, and unions pending/failed. This lets agents run in
  # separate passes — the expensive fresh glm/claude passes, the cheap reused 4.7
  # pass — without re-running everything to get a single artifact.
  #
  # Cells are merged by (agent_id, task_id): when the SAME cell appears in more
  # than one file — e.g. the inline run scored it with opus and a later rejudge
  # backfilled gpt-5.5-pro — their `judges` maps are unioned into one dual-judged
  # cell, and the richer `efficiency`/`gate` is kept (a judge-only rejudge carries
  # no generation telemetry, so it must not clobber the run's cost/wall-clock).
  module Merge
    module_function

    def combine(results_list, corpus_version:, generated_at:, scorer: Score.new)
      cells = merge_cells(results_list.flat_map { |r| r["cells"] || [] })
      out = scorer.results(records: cells, corpus_version: corpus_version, generated_at: generated_at)
      out["pending"] = results_list.flat_map { |r| r["pending"] || [] }
      out["failed"] = results_list.flat_map { |r| r["failed"] || [] }
      out
    end

    def merge_cells(cells)
      cells.group_by { |c| [c["agent_id"], c["task_id"]] }
           .map { |_, group| group.reduce { |acc, c| merge_pair(acc, c) } }
    end

    # b's scalar fields win, but judges are unioned and efficiency/gate keep the
    # non-empty side so a judge-only backfill never erases generation telemetry.
    def merge_pair(prev, cur)
      prev.merge(cur).merge(
        "judges" => (prev["judges"] || {}).merge(cur["judges"] || {}),
        "efficiency" => richer(prev["efficiency"], cur["efficiency"]),
        "gate" => richer(prev["gate"], cur["gate"])
      )
    end

    def richer(old, new)
      new.nil? || new.empty? ? (old || {}) : new
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require "optparse"
  require "fileutils"

  opts = { out: "runs/results.json", corpus_version: "v1" }
  OptionParser.new do |o|
    o.banner = "Usage: ruby harness/merge_results.rb [--out PATH] [--corpus-version V] <results.json>..."
    o.on("--out PATH", "combined output (default: runs/results.json)") { |v| opts[:out] = v }
    o.on("--corpus-version V", "default: v1") { |v| opts[:corpus_version] = v }
  end.parse!(ARGV)
  abort("give at least one results.json to merge") if ARGV.empty?

  results = ARGV.map { |p| JSON.parse(File.read(p)) }
  combined = HiveBench::Merge.combine(results, corpus_version: opts[:corpus_version],
                                               generated_at: Time.now.utc.iso8601)
  FileUtils.mkdir_p(File.dirname(opts[:out]))
  File.write(opts[:out], "#{JSON.pretty_generate(combined)}\n")
  warn "merged #{ARGV.size} file(s) -> #{opts[:out]}: #{combined["cells"].size} cells, " \
       "agents=#{combined["agents"].keys.sort.join(", ")}"
end
