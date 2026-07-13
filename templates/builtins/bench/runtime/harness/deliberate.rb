# frozen_string_literal: true

# Runs judge DELIBERATION over already-generated cells: round 1 re-grades each
# diff independently (with reasons), round 2 shares the anonymized verdicts and
# each judge writes a discussion + final score. Output is a transcript file for
# analysis — it never touches the leaderboard results.json (the published score
# stays the independent mean; see lib/deliberation.rb for why).
#
#   OPENROUTER_API_KEY=… ruby harness/deliberate.rb --source <clone> \
#     --results runs/v2-merged/results.json --out runs/v2-merged/deliberation.json <search-dir>...
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

require "json"
require "optparse"
require "fileutils"
require "lib/deliberation"
require "lib/corpus"
require "lib/git_restore"
require "lib/claude_judge"
require "lib/openrouter_judge"
require "lib/codex_judge"
require "lib/judge_provenance"
require "rejudge"

module HiveBench
  module DeliberateCli
    module_function

    def run(cells:, search_dirs:, source:, corpus_root:, judge_fns:, withhold_reference: false,
            plan_source: :frozen, judge_efforts: {})
      bases = Corpus.load(root: corpus_root, checkout_source: source)
                    .to_h { |e| [e["task_id"], { base: e.dig("source", "base_commit"), entry: e }] }
      restorer = GitRestore.new
      delib = Deliberation.new(judge_fns: judge_fns)
      transcripts = cells.filter_map do |cell|
        info = bases[cell["task_id"]] or next
        diff = Rejudge.recover_diff(search_dirs, cell, info[:base], restorer)
        next if diff.strip.empty?

        plan = if plan_source == :candidate
                 Rejudge.candidate_plan(search_dirs, cell) || Rejudge.read_plan(info[:entry])
               else
                 Rejudge.read_plan(info[:entry])
               end
        reference = withhold_reference ? nil : Rejudge.read_reference(info[:entry])
        verdicts = delib.call(plan: plan, candidate_diff: diff, reference: reference)
        next if verdicts.empty?

        warn "  deliberated #{cell["agent_id"]} #{cell["task_id"]}: " +
             verdicts.map { |n, v| "#{n} #{v.initial}->#{v.final || "?"}" }.join("  ")
        transcript(cell, verdicts, judge_efforts: judge_efforts)
      end
      { "schema" => "hive-bench-deliberation", "schema_version" => 1,
        "cells" => transcripts, "summary" => summary(transcripts) }
    end

    def transcript(cell, verdicts, judge_efforts: {})
      { "task_id" => cell["task_id"], "agent_id" => cell["agent_id"],
        "judges" => verdicts.to_h do |name, v|
          record = { "initial" => v.initial, "initial_reason" => v.initial_reason,
                     "final" => v.final, "final_reason" => v.final_reason,
                     "discussion" => v.discussion, "revised" => v.revised?, "delta" => v.delta }
          [name, record.merge(JudgeProvenance.metadata(name, efforts: judge_efforts))]
        end }
    end

    # Aggregate movement: how far each judge moved, and whether discussion
    # narrowed the inter-judge spread (convergence) — the anchoring telltale.
    def summary(transcripts)
      per_judge = Hash.new { |h, k| h[k] = [] }
      spreads = { before: [], after: [] }
      transcripts.each do |t|
        js = t["judges"].values
        if js.size >= 2
          spreads[:before] << (js.map { |j| j["initial"] }.max - js.map { |j| j["initial"] }.min)
          finals = js.map { |j| j["final"] || j["initial"] }
          spreads[:after] << (finals.max - finals.min)
        end
        t["judges"].each { |name, j| per_judge[name] << j["delta"] if j["delta"] }
      end
      {
        "cells" => transcripts.size,
        "mean_revision_by_judge" => per_judge.transform_values { |d| (d.sum / d.size).round(3) },
        "mean_abs_revision_by_judge" => per_judge.transform_values { |d| (d.sum(&:abs) / d.size).round(3) },
        "mean_spread_before" => mean(spreads[:before]),
        "mean_spread_after" => mean(spreads[:after])
      }
    end

    def mean(values) = values.empty? ? nil : (values.sum.to_f / values.size).round(3)
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { source: nil, corpus: "corpus", results: "runs/v2-merged/results.json",
           out: "runs/v2-merged/deliberation.json", claude_judge: true, judge_model: nil,
           codex_judge: false, codex_judge_model: HiveBench::CodexJudge::DEFAULT_MODEL,
           codex_judge_effort: HiveBench::CodexJudge::DEFAULT_EFFORT,
           openrouter_judge: true,
           openrouter_model: "openai/gpt-5.5-pro", max_tokens: 16_384,
           agent: nil, task: nil, withhold_reference: false,
           min_disagreement: 1.5, skip_done: nil, plan_source: :frozen }
  OptionParser.new do |o|
    o.banner = "Usage: OPENROUTER_API_KEY=… ruby harness/deliberate.rb --source <clone> [opts] <search-dir>..."
    o.on("--source PATH") { |v| opts[:source] = v }
    o.on("--corpus DIR") { |v| opts[:corpus] = v }
    o.on("--results PATH") { |v| opts[:results] = v }
    o.on("--out PATH") { |v| opts[:out] = v }
    o.on("--agent ID", "only this candidate's cells") { |v| opts[:agent] = v }
    o.on("--task SLUG", "only this task's cells") { |v| opts[:task] = v }
    o.on("--max-tokens N", Integer) { |v| opts[:max_tokens] = v }
    o.on("--[no-]claude-judge") { |v| opts[:claude_judge] = v }
    o.on("--judge-model M") { |v| opts[:judge_model] = v }
    o.on("--[no-]codex-judge") { |v| opts[:codex_judge] = v }
    o.on("--codex-judge-model M") { |v| opts[:codex_judge_model] = v }
    o.on("--codex-judge-effort LEVEL") { |v| opts[:codex_judge_effort] = v }
    o.on("--[no-]openrouter-judge") { |v| opts[:openrouter_judge] = v }
    o.on("--openrouter-model M") { |v| opts[:openrouter_model] = v }
    o.on("--[no-]withhold-reference") { |v| opts[:withhold_reference] = v }
    o.on("--min-disagreement N", Float, "only deliberate cells whose stored judge means differ " \
                                        "by >= N (default 1.5; 0 = all dual-judged cells)") { |v| opts[:min_disagreement] = v }
    o.on("--skip-done PATH", "skip cells already in this deliberation transcript") { |v| opts[:skip_done] = v }
    o.on("--plan-source SRC", %w[frozen candidate]) { |v| opts[:plan_source] = v.to_sym }
  end.parse!(ARGV)
  abort("--source is required") unless opts[:source]
  abort("give at least one search-dir") if ARGV.empty?

  claude_model = opts[:judge_model] || "claude-fable-5"
  judge_fns = {}
  judge_efforts = {}
  judge_fns[claude_model.sub(/\Aclaude-/, "")] = HiveBench::ClaudeJudge.judge_fn(model: claude_model) if opts[:claude_judge]
  if opts[:codex_judge]
    judge_fns[opts[:codex_judge_model]] =
      HiveBench::CodexJudge.judge_fn(model: opts[:codex_judge_model], effort: opts[:codex_judge_effort])
    judge_efforts[opts[:codex_judge_model]] = opts[:codex_judge_effort]
  end
  if opts[:openrouter_judge]
    judge_fns[opts[:openrouter_model].split("/").last] =
      HiveBench::OpenRouterJudge.judge_fn(model: opts[:openrouter_model], max_tokens: opts[:max_tokens])
  end
  abort("deliberation needs at least two enabled judges") if judge_fns.size < 2

  cells = JSON.parse(File.read(opts[:results]))["cells"]
  cells = cells.select { |c| c["agent_id"] == opts[:agent] } if opts[:agent]
  cells = cells.select { |c| c["task_id"] == opts[:task] } if opts[:task]
  # Deliberation only makes sense where both judges already scored the cell —
  # and only pays for itself where they DISAGREE (the pilot showed agreeing
  # judges simply hold their scores; discussing agreement is wasted tokens).
  cells = cells.select { |c| (c["judges"] || {}).size >= 2 }
  if opts[:min_disagreement].positive?
    cells = cells.select do |c|
      means = c["judges"].values.filter_map { |j| j["mean"] }
      means.size >= 2 && (means.max - means.min) >= opts[:min_disagreement]
    end
  end
  if opts[:skip_done] && File.file?(opts[:skip_done])
    seen = JSON.parse(File.read(opts[:skip_done]))["cells"].to_a
               .to_set { |t| [t["task_id"], t["agent_id"]] }
    cells = cells.reject { |c| seen.include?([c["task_id"], c["agent_id"]]) }
  end
  warn "deliberating #{cells.size} cell(s) (min_disagreement=#{opts[:min_disagreement]})"

  out = HiveBench::DeliberateCli.run(cells: cells, search_dirs: ARGV, source: opts[:source],
                                     corpus_root: opts[:corpus], judge_fns: judge_fns,
                                     withhold_reference: opts[:withhold_reference],
                                     plan_source: opts[:plan_source], judge_efforts: judge_efforts)
  FileUtils.mkdir_p(File.dirname(opts[:out]))
  File.write(opts[:out], "#{JSON.pretty_generate(out)}\n")
  warn "wrote #{opts[:out]}: #{out["cells"].size} deliberated cell(s); summary=#{out["summary"].inspect}"
end
