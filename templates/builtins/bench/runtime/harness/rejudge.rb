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
require "lib/agent_limit"
require "lib/judge_slate"
require "lib/generation_provenance"

module HiveBench
  # Offline re-judge: same scoring contract as RunAll, but the diff comes from
  # existing artifacts instead of a fresh generation.
  module Rejudge
    FAILURE_EVENT_VERSION = 1

    module_function

    NO_GATE = Gate::Result.new(status: :no_gate, subset: "judged", reason: "rejudge (no gate)", details: {})

    # withhold_reference: v1 rejudges graded on plan+diff alone; v2 cells are
    # judged vs the gold (RunAll runs withhold_reference: false), so a backfill
    # must match or its scores aren't comparable with the pass they fill.
    # only_missing_judges: skip judges the cell already has a score from — a
    # backfill must never re-buy existing scores.
    def run(cells: nil, document: nil, search_dirs:, source:, corpus_root:, judges:, scorer: Score.new,
            restorer: GitRestore.new, withhold_reference: false, only_missing_judges: false,
            plan_source: :frozen, judge_efforts: {}, judge_routes: {}, minimum_samples: 1)
      document ||= { "cells" => cells || [] }
      cells ||= document.fetch("cells", [])
      history = Array(document["generation_history"]).dup
      bases = Corpus.load(root: corpus_root, checkout_source: source)
                    .to_h { |e| [e["task_id"], { base: e.dig("source", "base_commit"), entry: e }] }
      records = cells.map do |old|
        rejudge_cell(old, bases, search_dirs, judges, scorer, restorer,
                     withhold_reference: withhold_reference, only_missing: only_missing_judges,
                     plan_source: plan_source, minimum_samples: minimum_samples,
                     judge_efforts: judge_efforts, judge_routes: judge_routes, history: history)
      end
      derived = scorer.results(records: records, corpus_version: document.fetch("corpus_version", "v2"),
                                generated_at: Time.now.utc.iso8601,
                                pending: document.fetch("pending", []), failed: document.fetch("failed", []))
      result = document.merge(derived)
      # Schema metadata is informational. Preserving it never relaxes admission.
      %w[schema schema_version pending failed].each { |key| result[key] = document[key] if document.key?(key) }
      result["generation_history"] = ResultEvidence.deduplicate_history(history)
      result
    end

    def rejudge_cell(old, bases, search_dirs, judges, scorer, restorer, withhold_reference:, only_missing:,
                     plan_source: :frozen, minimum_samples: 1, judge_efforts: {}, judge_routes: {}, history: [])
      info = bases.fetch(old["task_id"])
      bundle = artifact_bundle(search_dirs, old, info, restorer, plan_source: plan_source)
      reference = withhold_reference ? nil : read_reference(info[:entry])
      context = GenerationProvenance.context(plan: bundle[:plan], reference: reference, withheld: withhold_reference)
      manifest = bundle.fetch(:manifest)
      prepared = old.merge(manifest.slice("generation_id", "artifact_binding"))
                    .merge("record_kind" => "judge_only", "evaluation_context" => context)
                    .reject { |key, _| %w[artifact_verification_error provenance_conflict rejudging_reasons].include?(key) }
      if old["generation_id"].to_s.empty?
        prepared["adopted_attempt_snapshot_sha256"] = ResultEvidence.snapshot_digest(old)
      end
      continuity = !bundle[:adopted] && ResultEvidence.same_generation?(old, prepared) && old["evaluation_context"] == context
      history << ResultEvidence.history_entry(old, "legacy or incompatible evaluations require fresh judging") unless continuity
      existing = continuity ? (old["judges"] || {}).select { |_, j| ResultEvidence.evaluation_bound?(prepared, j) } : {}
      wanted = judges.reject do |name, _|
        only_missing && existing.key?(name) && judge_satisfied?(existing[name], minimum_samples: minimum_samples,
                                                               expected_effort: judge_efforts[name] || judge_efforts[name.to_sym])
      end
      judged = bundle[:diff].strip.empty? ? {} : judge_all(wanted, bundle[:plan], bundle[:diff], reference,
                                                         task_id: old["task_id"], agent_id: old["agent_id"])
      fresh = scorer.cell_record(cell: cell_meta(prepared), gate: NO_GATE, judges: judged).fetch("judges")
      fresh.each { |name, record| record.merge!(JudgeProvenance.metadata(name, efforts: judge_efforts, routes: judge_routes)) }
      prepared.merge("judges" => merge_judge_records(existing, fresh, judge_efforts))
    rescue GenerationProvenance::Mismatch, KeyError => error
      old.merge("artifact_verification_error" => "artifact recovery/rejudging required: #{error.message}")
    end

    # Choose one bundle first, then read both patch and plan from it. Directory
    # names and patch equality cannot establish continuity with old evaluations.
    def artifact_bundle(search_dirs, old, info, restorer, plan_source: :frozen)
      entry = info.fetch(:entry).merge("task_id" => old["task_id"], "source" => { "base_commit" => info.fetch(:base) })
      paths = search_dirs.map { |dir| File.join(dir, old["task_id"], cell_dir(old["agent_id"])) }
                         .select { |path| File.directory?(path) }.map { |path| File.realpath(path) }.uniq
      if !old["generation_id"].to_s.empty?
        paths = paths.select { |path| GenerationProvenance.load(path)&.fetch("generation_id", nil) == old["generation_id"] }
      end
      raise GenerationProvenance::Mismatch, "missing provenance-matched artifact bundle" if paths.empty?
      # Multiple copies of the same finalized identity can be inspected, but all
      # copies must verify. Unidentified legacy copies remain ambiguous.
      raise GenerationProvenance::Mismatch, "ambiguous legacy artifact bundles; select one search directory" if paths.size > 1 && old["generation_id"].to_s.empty?

      bundles = paths.map do |path|
        manifest = GenerationProvenance.load(path)
        adopted = false
        if manifest && manifest["artifact_binding"]
          GenerationProvenance.verify!(path, entry: entry, agent_id: old["agent_id"])
          if old["artifact_binding"] && old["artifact_binding"] != manifest["artifact_binding"]
            raise GenerationProvenance::Mismatch, "result/artifact binding conflict"
          end
        else
          diff_path = existing_patch(path, old, info[:base], restorer)
          plan = bundle_plan(path, old, entry, plan_source)
          if manifest
            unless manifest["task_id"] == old["task_id"] && manifest["agent_id"] == old["agent_id"] && manifest["base_commit"] == info[:base]
              raise GenerationProvenance::Mismatch, "attempt task/agent/base mismatch"
            end
          else
            manifest = GenerationProvenance.start!(out_dir: path, entry: entry, agent_id: old["agent_id"], clear_artifacts: false)
          end
          manifest = GenerationProvenance.finalize!(out_dir: path, manifest: manifest, diff_path: diff_path, plan: plan,
                                                     status: old["run_status"], telemetry: old["efficiency"] || {}, state: "recovery-finalized")
          adopted = true
        end
        diff_path = GenerationProvenance.artifact_path(path, manifest["patch_path"])
        plan = plan_source == :candidate ? File.read(GenerationProvenance.artifact_path(path, manifest["plan_path"])) : read_plan(entry)
        { manifest: manifest, diff: File.read(diff_path), plan: plan, adopted: adopted }
      end
      unless bundles.all? { |bundle| bundle[:manifest]["artifact_binding"] == bundles.first[:manifest]["artifact_binding"] }
        raise GenerationProvenance::Mismatch, "conflicting copies of generation artifacts"
      end
      bundles.first
    end

    def existing_patch(path, old, base, restorer)
      final = File.join(path, "target", "candidate.patch")
      execute = File.join(path, "target", "candidate-execute.patch")
      transcript = File.join(path, "target", ".hb", "stages.out")
      if !File.file?(final) && File.file?(execute) && File.file?(transcript)
        text = File.read(transcript)
        if text.match?(/^HB_EXIT rc=124$/) && %w[plan develop].all? { |stage| text.match?(/^HB_STAGE #{stage} rc=0$/) }
          FileUtils.cp(execute, "#{final}.next")
          File.rename("#{final}.next", final)
        end
      end
      patch = [final, File.join(path, "candidate.patch")].find { |candidate| File.file?(candidate) }
      return patch if patch

      work = File.join(path, "work")
      if old["mode"] != "reused" && File.directory?(File.join(work, ".git"))
        patch = File.join(path, "candidate.patch")
        File.write(patch, restorer.diff(work_dir: work, base_commit: base))
        return patch
      end
      raise GenerationProvenance::Mismatch, "missing patch artifact (not an observed empty patch)"
    end

    def bundle_plan(path, old, entry, plan_source)
      return read_plan(entry) unless plan_source == :candidate

      stored = File.join(path, "generation-plan.md")
      pipeline = File.join(path, "plan_work", "HIVE_BENCH_PLAN.md")
      return File.read(stored) if File.file?(stored)
      return File.read(pipeline) if File.file?(pipeline)

      plans = Dir.glob(File.join(path, "target", ".hive-state", "stages", "**", old["task_id"], "plan.md"))
      raise GenerationProvenance::Mismatch, "missing or ambiguous candidate plan in artifact bundle" unless plans.size == 1

      File.read(plans.first)
    end

    def merge_judge_records(existing, fresh, judge_efforts)
      judge_efforts = normalize_judge_efforts(judge_efforts)
      annotate_fresh_judges!(fresh, judge_efforts)
      merged = (existing || {}).merge(fresh || {}).transform_values do |record|
        record.is_a?(Hash) ? record.dup : record
      end
      annotate_missing_provenance!(merged)
      merged
    end

    # Score records carry the repository-wide default provenance. A rejudge can
    # pin a different effort, so stamp only records produced by this invocation
    # before merging them with untouched incumbent judges. Applying the pin to
    # the whole document would falsely relabel judges that were skipped.
    def annotate_fresh_judges!(records, judge_efforts)
      (records || {}).each do |judge_name, record|
        next unless record.is_a?(Hash)

        JudgeProvenance.metadata(judge_name, efforts: judge_efforts).each do |key, value|
          record[key] = value
        end
      end
    end

    # Legacy incumbents can predate provenance fields. Fill only absent keys
    # from the repository defaults; never apply this invocation's effort pin to
    # a skipped or failed replacement, because that would relabel old evidence.
    def annotate_missing_provenance!(records)
      (records || {}).each do |judge_name, record|
        next unless record.is_a?(Hash)

        JudgeProvenance.metadata(judge_name).each do |key, value|
          record[key] = value unless record.key?(key)
        end
      end
    end

    def normalize_judge_efforts(judge_efforts)
      (judge_efforts || {}).transform_keys(&:to_s)
    end

    # Fail soft per judge: a flaky/limited judge (e.g. an OpenRouter key-limit 403)
    # is skipped with a warning rather than crashing the whole re-judge — the cell
    # keeps the judges that succeeded, and the failed one can be re-run later.
    def judge_all(judges, plan, diff, reference, task_id:, agent_id:)
      judges.each_with_object({}) do |(name, judge), acc|
        acc[name] = judge.call(plan: plan, candidate_diff: diff, reference: reference)
      rescue StandardError => e
        failure = "#{e.class}: #{e.message}"
        warn JudgeSlate.failure_event(
          task_id: task_id,
          agent_id: agent_id,
          judge: name,
          limits_reached: e.is_a?(ProviderLimitError),
          detail: failure
        )
      end
    end

    def judge_satisfied?(record, minimum_samples:, expected_effort: nil)
      return false unless ResultEvidence.valid_judge?(record)
      return false if expected_effort && record["reasoning_effort"] != expected_effort

      stored_samples = record["sample_count"] || Array(record["scores"]).size
      stored_samples = 1 if stored_samples.to_i.zero? && record.key?("mean")
      stored_samples.to_i >= minimum_samples
    end

    def read_reference(entry)
      path = File.join(entry.fetch("entry_dir"), "reference.patch")
      File.file?(path) ? File.read(path) : nil
    end

    def candidate_plan(search_dirs, old)
      paths = search_dirs.map { |dir| File.join(dir, old["task_id"], cell_dir(old["agent_id"])) }
                         .select { |path| File.directory?(path) }
      raise GenerationProvenance::Mismatch, "candidate plan requires one selected bundle" unless paths.size == 1

      bundle_plan(paths.first, old, {}, :candidate)
    end

    def recover_diff(search_dirs, old, base, restorer)
      paths = search_dirs.map { |dir| File.join(dir, old["task_id"], cell_dir(old["agent_id"])) }
                         .select { |path| File.directory?(path) }
      raise GenerationProvenance::Mismatch, "diff requires one selected artifact bundle" unless paths.size == 1

      File.read(existing_patch(paths.first, old, base, restorer))
    end

    def cell_meta(old)
      { task_id: old["task_id"], agent_id: old["agent_id"], mode: old["mode"],
        model_version: old["model_version"], run_status: old["run_status"], telemetry: old["efficiency"] || {}, record_kind: old["record_kind"],
        generation_id: old["generation_id"], artifact_binding: old["artifact_binding"], evaluation_context: old["evaluation_context"] }
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
  opts[:codex_judge_provider] = HiveBench::CodexJudge::DEFAULT_PROVIDER
  opts[:codex_judge_provider_model] = nil
  OptionParser.new do |o|
    o.banner = "Usage: OPENROUTER_API_KEY=… ruby harness/rejudge.rb --source <clone> [opts] <search-dir>..."
    o.on("--source PATH") { |v| opts[:source] = v }
    o.on("--corpus DIR") { |v| opts[:corpus] = v }
    o.on("--results PATH", "results.json holding the cells to re-judge") { |v| opts[:results] = v }
    o.on("--out PATH") { |v| opts[:out] = v }
    o.on("--seeds N", Integer) { |v| opts[:seeds] = v }
    o.on("--[no-]claude-judge") { |v| opts[:claude_judge] = v }
    o.on("--judge-model M") { |v| opts[:judge_model] = v }
    o.on("--[no-]codex-judge", "score via the codex CLI (subscription by default)") { |v| opts[:codex_judge] = v }
    o.on("--codex-judge-model M", "default: #{HiveBench::CodexJudge::DEFAULT_MODEL}") { |v| opts[:codex_judge_model] = v }
    o.on("--codex-judge-effort LEVEL", "default: #{HiveBench::CodexJudge::DEFAULT_EFFORT}") do |v|
      opts[:codex_judge_effort] = v
    end
    o.on("--codex-judge-provider PROVIDER", HiveBench::CodexJudge::PROVIDERS,
         "default: #{HiveBench::CodexJudge::DEFAULT_PROVIDER}") { |v| opts[:codex_judge_provider] = v }
    o.on("--codex-judge-provider-model M", "provider model id (required for OpenRouter)") do |v|
      opts[:codex_judge_provider_model] = v
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
                                                 effort: opts[:codex_judge_effort],
                                                 provider: opts[:codex_judge_provider],
                                                 provider_model: opts[:codex_judge_provider_model]),
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

  document = JSON.parse(File.read(opts[:results]))
  judge_efforts = opts[:codex_judge] ? { opts[:codex_judge_model] => opts[:codex_judge_effort] } : {}
  judge_routes = if opts[:codex_judge]
                   { opts[:codex_judge_model] => {
                     provider: opts[:codex_judge_provider],
                     provider_model: opts[:codex_judge_provider_model] || opts[:codex_judge_model]
                   } }
                 else
                   {}
                 end
  results = HiveBench::Rejudge.run(document: document, search_dirs: ARGV, source: opts[:source],
                                   corpus_root: opts[:corpus], judges: judges,
                                   withhold_reference: opts[:withhold_reference], plan_source: opts[:plan_source],
                                   only_missing_judges: opts[:only_missing], minimum_samples: opts[:seeds],
                                   judge_efforts: judge_efforts, judge_routes: judge_routes)
  FileUtils.mkdir_p(File.dirname(opts[:out]))
  File.write(opts[:out], "#{JSON.pretty_generate(results)}\n")
  warn "wrote #{opts[:out]}: #{results["cells"].size} cells re-judged by #{judges.keys.join(" + ")}"
end
