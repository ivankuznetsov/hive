# frozen_string_literal: true

# Re-scores ALREADY-GENERATED cells without re-running the agents: re-captures
# each fresh cell's diff from its work tree (picking up the new-files capture
# fix) and judges every cell with one or more judges, then writes a combined
# results.json. Reused incumbent cells keep their recorded candidate.patch.
#
#   OPENROUTER_API_KEY=… ruby harness/rejudge.rb --source <clone> \
#     --results runs/results.json --out runs/results.json <search-dir>...
#
# Cells (and their original telemetry) come from --results; each cell's artifacts
# (work/ or candidate.patch) are located by searching the given run dirs for
# <dir>/<task>/<cell>. No generation is re-run.
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

require "json"
require "optparse"
require "fileutils"
require "score"
require "gate"
require "judge"
require "lib/corpus"
require "lib/git_restore"
require "lib/claude_judge"
require "lib/openrouter_judge"
require "lib/codex_judge"
require "lib/judge_provenance"

module HiveBench
  # Offline re-judge: same scoring contract as RunAll, but the diff comes from
  # existing artifacts instead of a fresh generation.
  module Rejudge
    module_function

    NO_GATE = Gate::Result.new(status: :no_gate, subset: "judged", reason: "rejudge (no gate)", details: {})

    # withhold_reference: v1 rejudges graded on plan+diff alone; v2 cells are
    # judged vs the gold (RunAll runs withhold_reference: false), so a backfill
    # must match or its scores aren't comparable with the pass they fill.
    # only_missing_judges: skip judges the cell already has a score from — a
    # backfill must never re-buy existing scores.
    def run(cells:, search_dirs:, source:, corpus_root:, judges:, scorer: Score.new,
            restorer: GitRestore.new, withhold_reference: false, only_missing_judges: false,
            plan_source: :frozen, judge_efforts: {}, minimum_samples: 1)
      bases = Corpus.load(root: corpus_root, checkout_source: source)
                    .to_h { |e| [e["task_id"], { base: e.dig("source", "base_commit"), entry: e }] }
      records = cells.map do |old|
        rejudge_cell(old, bases, search_dirs, judges, scorer, restorer,
                     withhold_reference: withhold_reference, only_missing: only_missing_judges,
                     plan_source: plan_source, minimum_samples: minimum_samples)
      end
      result = scorer.results(records: records, corpus_version: "v2", generated_at: Time.now.utc.iso8601)
      JudgeProvenance.annotate_document!(result, efforts: judge_efforts)
    end

    def rejudge_cell(old, bases, search_dirs, judges, scorer, restorer, withhold_reference:, only_missing:,
                     plan_source: :frozen, minimum_samples: 1)
      info = bases.fetch(old["task_id"])
      diff = recover_diff(search_dirs, old, info[:base], restorer)
      # Task contract (external review, threat #4): v2 graded every cell against
      # the FROZEN plan while candidates re-planned from idea+brainstorm — kept
      # as the default so backfills stay comparable with the published board.
      # :candidate grades against the cell's own generated plan (the v3 contract).
      plan = plan_source == :candidate ? candidate_plan(search_dirs, old) || read_plan(info[:entry]) : read_plan(info[:entry])
      reference = withhold_reference ? nil : read_reference(info[:entry])
      wanted = if only_missing
                 judges.reject do |name, _|
                   judge_satisfied?((old["judges"] || {})[name], minimum_samples: minimum_samples)
                 end
               else
                 judges
               end
      judged = diff.strip.empty? ? {} : judge_all(wanted, plan, diff, reference)
      warn "  judged #{old["agent_id"]} #{old["task_id"]} (#{diff.lines.size} diff lines): #{judged.transform_values(&:mean).inspect}"
      rec = scorer.cell_record(cell: cell_meta(old), gate: NO_GATE, judges: judged)
      # Keep the cell's existing judge scores; the fresh ones fill the gaps.
      rec["judges"] = (old["judges"] || {}).merge(rec["judges"] || {})
      rec
    end

    # Fail soft per judge: a flaky/limited judge (e.g. an OpenRouter key-limit 403)
    # is skipped with a warning rather than crashing the whole re-judge — the cell
    # keeps the judges that succeeded, and the failed one can be re-run later.
    def judge_all(judges, plan, diff, reference)
      judges.each_with_object({}) do |(name, judge), acc|
        acc[name] = judge.call(plan: plan, candidate_diff: diff, reference: reference)
      rescue StandardError => e
        warn "  judge #{name} failed (#{e.class}: #{e.message.to_s[0, 80]}) — skipping this judge"
      end
    end

    def judge_satisfied?(record, minimum_samples:)
      return false unless record

      stored_samples = record["sample_count"] || Array(record["scores"]).size
      stored_samples = 1 if stored_samples.to_i.zero? && record.key?("mean")
      stored_samples.to_i >= minimum_samples
    end

    def read_reference(entry)
      path = File.join(entry.fetch("entry_dir"), "reference.patch")
      File.file?(path) ? File.read(path) : nil
    end

    # The plan the CANDIDATE generated inside its own cell (v3 contract).
    def candidate_plan(search_dirs, old)
      cell_path = search_dirs.map { |d| File.join(d, old["task_id"], cell_dir(old["agent_id"])) }
                             .find { |p| File.directory?(p) } or return nil
      plan = Dir.glob(File.join(cell_path, "target", ".hive-state", "stages", "**", old["task_id"], "plan.md")).first
      plan && File.read(plan)
    end

    # v2 cells persist the final diff at <cell>/target/candidate.patch (the
    # hive driver's capture); v1 fresh cells re-capture from <cell>/work.
    # Reused/other: the recorded candidate.patch at the cell root.
    def recover_diff(search_dirs, old, base, restorer)
      cell_path = search_dirs.map { |d| File.join(d, old["task_id"], cell_dir(old["agent_id"])) }
                             .find { |p| File.directory?(p) }
      return "" unless cell_path

      v2_patch = File.join(cell_path, "target", "candidate.patch")
      return File.read(v2_patch) if File.file?(v2_patch)

      work = File.join(cell_path, "work")
      if old["mode"] != "reused" && File.directory?(File.join(work, ".git"))
        restorer.diff(work_dir: work, base_commit: base)
      else
        patch = File.join(cell_path, "candidate.patch")
        File.file?(patch) ? File.read(patch) : ""
      end
    end

    def cell_meta(old)
      { task_id: old["task_id"], agent_id: old["agent_id"], mode: old["mode"],
        model_version: old["model_version"], run_status: old["run_status"], telemetry: old["efficiency"] || {} }
    end

    def read_plan(entry)
      rel = entry.dig("spec", "plan")
      path = rel && File.join(entry.fetch("entry_dir"), rel)
      path && File.file?(path) ? File.read(path) : ""
    end

    def cell_dir(agent_id) = agent_id.gsub(/[^a-z0-9]+/i, "_")
  end
end

if $PROGRAM_NAME == __FILE__
  opts = { source: nil, corpus: "corpus", results: "runs/results.json", out: "runs/results.json",
           seeds: 1, claude_judge: true, judge_model: nil, codex_judge: false, openrouter_judge: true,
           openrouter_model: "openai/gpt-5.5-pro", withhold_reference: false, only_missing: false, plan_source: :frozen }
  opts[:codex_judge_model] = HiveBench::CodexJudge::DEFAULT_MODEL
  opts[:codex_judge_effort] = HiveBench::CodexJudge::DEFAULT_EFFORT
  OptionParser.new do |o|
    o.banner = "Usage: OPENROUTER_API_KEY=… ruby harness/rejudge.rb --source <clone> [opts] <search-dir>..."
    o.on("--source PATH") { |v| opts[:source] = v }
    o.on("--corpus DIR") { |v| opts[:corpus] = v }
    o.on("--results PATH", "results.json holding the cells to re-judge") { |v| opts[:results] = v }
    o.on("--out PATH") { |v| opts[:out] = v }
    o.on("--seeds N", Integer) { |v| opts[:seeds] = v }
    o.on("--[no-]claude-judge") { |v| opts[:claude_judge] = v }
    o.on("--judge-model M") { |v| opts[:judge_model] = v }
    o.on("--[no-]codex-judge", "score via the codex CLI (subscription)") { |v| opts[:codex_judge] = v }
    o.on("--codex-judge-model M", "default: #{HiveBench::CodexJudge::DEFAULT_MODEL}") { |v| opts[:codex_judge_model] = v }
    o.on("--codex-judge-effort LEVEL", "default: #{HiveBench::CodexJudge::DEFAULT_EFFORT}") do |v|
      opts[:codex_judge_effort] = v
    end
    o.on("--[no-]openrouter-judge") { |v| opts[:openrouter_judge] = v }
    o.on("--openrouter-model M") { |v| opts[:openrouter_model] = v }
    o.on("--[no-]withhold-reference", "default off: judge vs the gold, matching v2 passes") { |v| opts[:withhold_reference] = v }
    o.on("--only-missing", "skip judges the cell already has a score from") { opts[:only_missing] = true }
    o.on("--max-tokens N", Integer, "openrouter judge output cap (reservation = cap x output rate; " \
                                    "lower it to backfill on a thin balance)") { |v| opts[:max_tokens] = v }
    o.on("--plan-source SRC", %w[frozen candidate],
         "what {{PLAN}} carries: frozen (v2 default, board-comparable) or candidate " \
         "(the cell's own generated plan — the v3 contract)") { |v| opts[:plan_source] = v.to_sym }
  end.parse!(ARGV)
  abort("--source is required") unless opts[:source]
  abort("give at least one search-dir") if ARGV.empty?

  judges = {}
  if opts[:claude_judge]
    model = opts[:judge_model] || "claude-fable-5"
    judges[model.sub(/\Aclaude-/, "")] =
      HiveBench::Judge.new(judge_fn: HiveBench::ClaudeJudge.judge_fn(model: model), seeds: opts[:seeds])
  end
  if opts[:codex_judge]
    judges[opts[:codex_judge_model]] =
      HiveBench::Judge.new(
        judge_fn: HiveBench::CodexJudge.judge_fn(model: opts[:codex_judge_model],
                                                 effort: opts[:codex_judge_effort]),
        seeds: opts[:seeds]
      )
  end
  if opts[:openrouter_judge]
    or_kwargs = { model: opts[:openrouter_model] }
    or_kwargs[:max_tokens] = opts[:max_tokens] if opts[:max_tokens]
    judges[opts[:openrouter_model].split("/").last] =
      HiveBench::Judge.new(judge_fn: HiveBench::OpenRouterJudge.judge_fn(**or_kwargs), seeds: opts[:seeds])
  end
  abort("no judges enabled") if judges.empty?

  cells = JSON.parse(File.read(opts[:results]))["cells"]
  judge_efforts = opts[:codex_judge] ? { opts[:codex_judge_model] => opts[:codex_judge_effort] } : {}
  results = HiveBench::Rejudge.run(cells: cells, search_dirs: ARGV, source: opts[:source],
                                   corpus_root: opts[:corpus], judges: judges,
                                   withhold_reference: opts[:withhold_reference], plan_source: opts[:plan_source],
                                   only_missing_judges: opts[:only_missing], minimum_samples: opts[:seeds],
                                   judge_efforts: judge_efforts)
  FileUtils.mkdir_p(File.dirname(opts[:out]))
  File.write(opts[:out], "#{JSON.pretty_generate(results)}\n")
  warn "wrote #{opts[:out]}: #{results["cells"].size} cells re-judged by #{judges.keys.join(" + ")}"
end
