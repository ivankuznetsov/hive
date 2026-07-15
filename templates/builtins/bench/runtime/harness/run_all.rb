# frozen_string_literal: true

# Make the harness dir importable when this file is run directly
# (`ruby harness/run_all.rb`); harmless when it is already on the path (tests).
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

require "yaml"
require "json"
require "run"
require "gate"
require "judge"
require "score"
require "lib/agent_limit"
require "lib/codex_judge"

module HiveBench
  # The benchmark-pass driver (plan U8): runs the full corpus × slate matrix and
  # emits results.json. For each cell it wires together the units below, so the
  # driver itself is thin orchestration — the heavy parts are tested in U3/U4.
  #
  #   Run (U3)   -> a candidate diff (reused or fresh) + telemetry
  #   Gate (U4)  -> objective pass/fail (judged subset when no gate)
  #   Judge (U4) -> blind quality score (skipped when there's no diff)
  #   Score (U4) -> per-cell record -> aggregated results.json
  #
  # A cell that hit a provider limit (Run status "limit_hit") is NOT scored — it
  # is collected as `pending` for a later re-run, never recorded as a failure.
  # All components are injected so a pass can be driven offline in tests.
  class RunAll
    Outcome = Data.define(:results, :pending, :failed)
    ScoredCell = Data.define(:record, :judge_failure)

    # Raised when EVERY judge failed on a generated cell (nothing to score). Carries
    # whether the wall was a provider usage/credit limit, so the caller can park the
    # cell as pending (re-judge after billing) rather than as a hard failure.
    class JudgesExhausted < StandardError
      attr_reader :limit

      def initialize(message, limit:)
        super(message)
        @limit = limit
      end
    end

    # judges: { "<name>" => HiveBench::Judge } — every cell is scored by each.
    # withhold_reference: grade on plan+diff alone for ALL cells (de-anchoring +
    # cheaper); reused incumbent cells are always reference-withheld regardless.
    def initialize(runner:, gate:, judges:, scorer: Score.new, withhold_reference: false, clock: -> { Time.now.utc })
      @runner = runner
      @gate = gate
      @judges = judges
      @scorer = scorer
      @withhold_reference = withhold_reference
      @clock = clock
    end

    # entries: array of corpus-entry hashes (manifest + entry_dir + checkout_source).
    # profiles: the candidate slate (HiveBench::Profile list).
    def call(entries:, profiles:, out_root:, corpus_version:)
      records = []
      pending = []
      failed = []

      entries.each do |entry|
        profiles.each do |profile|
          out_dir = File.join(out_root, entry.fetch("task_id"), cell_dir(profile))
          run_cell(entry, profile, out_dir, records, pending, failed)
        end
      end

      results = @scorer.results(records: records, corpus_version: corpus_version,
                                generated_at: @clock.call.iso8601)
      results["pending"] = pending
      results["failed"] = failed
      Outcome.new(results: results, pending: pending, failed: failed)
    end

    private

    # One matrix cell. ANY failure — an isolation refusal, an unwired harness, a
    # flaky judge, a git/restore error, a malformed gate spec — parks that cell in
    # `failed` and lets the pass keep the cells already produced (one bad cell must
    # not discard expensive prior work, and a score is never emitted from a failed
    # cell). A provider limit is parked in `pending` for re-run. The catch-all is
    # deliberate and loud (it warns), not silent: this is a long, expensive matrix.
    def run_cell(entry, profile, out_dir, records, pending, failed)
      cell = @runner.call(entry: entry, profile: profile, out_dir: out_dir)

      if cell.status == "limit_hit"
        pending << park(entry, profile, cell.reason)
        return
      end

      scored = score_cell(entry, profile, cell, out_dir)
      records << scored.record
      park_judge_failure(scored.judge_failure, entry, profile, pending, failed) if scored.judge_failure
    rescue StandardError => e
      reason = "#{e.class}: #{e.message}"
      warn "hive-bench: parked failed — #{profile.id} #{entry["task_id"]}: #{redact(reason)}"
      failed << park(entry, profile, reason)
    end

    def park(entry, profile, reason)
      { "task_id" => entry["task_id"], "agent_id" => profile.id, "reason" => redact(reason) }
    end

    # The diff generated fine but no judge could score it. A provider limit
    # (drained balance, 429) is transient; anything else is a hard judge failure.
    # In both cases the generated record is already preserved for rejudge.
    def park_judge_failure(error, entry, profile, pending, failed)
      bucket, label = error.limit ? [pending, "pending (judge limit)"] : [failed, "failed (all judges)"]
      warn "hive-bench: #{label} — #{profile.id} #{entry["task_id"]}: #{redact(error.message)}"
      bucket << park(entry, profile, error.message)
    end

    # Strip provider-secret shapes from any text persisted into results.json —
    # failed[].reason can carry container stderr, and results.json is shareable.
    def redact(text)
      text.to_s
          .gsub(/sk-[a-z]+-[A-Za-z0-9._-]{6,}/, "[REDACTED]")
          .gsub(/\b[A-Z0-9_]*API_KEY=\S+/, "[REDACTED]")
    end

    def score_cell(entry, _profile, cell, out_dir)
      gate_spec = load_gate(entry)
      candidate_patch = cell.diff_path ? File.read(cell.diff_path) : ""

      gate_res =
        if cell.diff_path && gate_spec
          @gate.call(entry: entry, gate_spec: gate_spec, candidate_patch: candidate_patch,
                     work_dir: File.join(out_dir, "gate"))
        else
          Gate::Result.new(status: :no_gate, subset: "judged", reason: "no diff or no gate", details: {})
        end

      judges_res = judge_cell(entry, candidate_patch, withhold_reference: @withhold_reference || cell.mode == "reused")
      ScoredCell.new(record: cell_record(cell, gate_res, judges_res), judge_failure: nil)
    rescue JudgesExhausted => e
      # Generation and gating already succeeded. Persist that paid artifact even
      # when every judge is unavailable so rejudge can backfill it later.
      ScoredCell.new(record: cell_record(cell, gate_res, {}), judge_failure: e)
    end

    def cell_record(cell, gate_res, judges_res)
      @scorer.cell_record(
        cell: { task_id: cell.task_id, agent_id: cell.agent_id, mode: cell.mode,
                model_version: cell.model_version, run_status: cell.status, telemetry: cell.telemetry },
        gate: gate_res, judges: judges_res
      )
    end

    # Judge a non-empty diff with EVERY judge, FAIL-SOFT per judge: a flaky or
    # usage-limited judge (e.g. an OpenRouter 402/403) is skipped with a warning so
    # its failure can't discard a successfully-generated cell or the OTHER judges'
    # scores — the missing judge is backfilled later (harness/rejudge.rb). reference
    # + plan come from the entry; a reused cell's diff IS the reference, so judging
    # it against the reference would be circular incumbent-anchoring — grade it on
    # the task alone (R24). Raises JudgesExhausted only when EVERY judge failed.
    # Returns { name => Judge::Result } (empty when there's no diff).
    def judge_cell(entry, candidate_patch, withhold_reference:)
      return {} if candidate_patch.strip.empty?

      plan = read_entry_file(entry, entry.dig("spec", "plan"))
      reference = withhold_reference ? nil : read_entry_file(entry, "reference.patch")
      results = {}
      failures = []
      @judges.each do |name, judge|
        results[name] = judge.call(plan: plan, candidate_diff: candidate_patch, reference: reference)
      rescue StandardError => e
        failures << "#{name}: #{e.class}: #{e.message}"
        warn "hive-bench: judge #{name} skipped — #{redact("#{e.class}: #{e.message}")[0, 140]} (backfill later)"
      end
      if results.empty? && !@judges.empty?
        raise JudgesExhausted.new(failures.join(" | "), limit: failures.any? { |f| AgentLimit.limit_hit?(f) })
      end

      results
    end

    def load_gate(entry)
      path = File.join(entry.fetch("entry_dir"), "gate", "gate.yml")
      File.file?(path) ? YAML.safe_load_file(path) : nil
    end

    def read_entry_file(entry, rel)
      return nil if rel.nil?

      path = File.join(entry.fetch("entry_dir"), rel)
      File.file?(path) ? File.read(path) : nil
    end

    def cell_dir(profile)
      profile.id.gsub(/[^a-z0-9]+/i, "_")
    end
  end

  # Wires the production seams (real GitRestore, the isolated gen/gate runners,
  # the local-claude judge) and drives a pass. Kept here so `ruby harness/run_all.rb`
  # is the single entrypoint the README documents.
  module Driver
    module_function

    def main(argv)
      require "optparse"
      require "fileutils"
      require "profiles/slate"
      require "lib/corpus"
      require "lib/git_restore"
      require "lib/isolation_exec"
      require "lib/claude_judge"
      require "lib/openrouter_judge"
      require "lib/reuse"

      opts = parse(argv)
      validate!(opts)

      entries = Corpus.load(root: opts[:corpus], checkout_source: opts[:source])
      abort("no corpus entries under #{opts[:corpus]}") if entries.empty?
      profiles = select_profiles(opts[:agent])

      outcome = build(opts).call(entries: entries, profiles: profiles,
                                 out_root: opts[:out], corpus_version: opts[:corpus_version])
      JudgeProvenance.annotate_document!(outcome.results, efforts: judge_efforts(opts))
      write_and_report(outcome, opts)
    end

    def parse(argv)
      opts = { corpus: "corpus", out: "runs", source: nil, agent: nil,
               seeds: 1, corpus_version: "v1", withhold_reference: true,
               claude_judge: true, judge_bin: "claude", judge_model: nil,
               codex_judge: false, codex_judge_model: CodexJudge::DEFAULT_MODEL,
               codex_judge_effort: CodexJudge::DEFAULT_EFFORT,
               openrouter_judge: true, openrouter_judge_model: "openai/gpt-5.5-pro" }
      OptionParser.new do |o|
        o.banner = "Usage: OPENROUTER_API_KEY=… ruby harness/run_all.rb --source <clone> [opts]"
        o.on("--corpus DIR", "corpus root (default: corpus)") { |v| opts[:corpus] = v }
        o.on("--out DIR", "output root (default: runs)") { |v| opts[:out] = v }
        o.on("--source PATH", "local clone restored at base_commit (required)") { |v| opts[:source] = v }
        o.on("--agent ID", "run only this slate cell, e.g. pi@glm-5.2") { |v| opts[:agent] = v }
        o.on("--seeds N", Integer, "judge seeds per judge (default: 1)") { |v| opts[:seeds] = v }
        o.on("--corpus-version V", "recorded in results.json (default: v1)") { |v| opts[:corpus_version] = v }
        o.on("--[no-]withhold-reference", "judge on plan+diff alone (default: on)") { |v| opts[:withhold_reference] = v }
        o.on("--[no-]claude-judge", "score with the local claude judge (default: on)") { |v| opts[:claude_judge] = v }
        o.on("--judge-bin BIN", "claude judge CLI binary (default: claude)") { |v| opts[:judge_bin] = v }
        o.on("--judge-model M", "claude judge model (default: claude-fable-5)") { |v| opts[:judge_model] = v }
        o.on("--[no-]codex-judge", "score through the Codex CLI") { |v| opts[:codex_judge] = v }
        o.on("--codex-judge-model M") { |v| opts[:codex_judge_model] = v }
        o.on("--codex-judge-effort LEVEL") { |v| opts[:codex_judge_effort] = v }
        o.on("--[no-]openrouter-judge", "score with the OpenRouter judge (default: on)") { |v| opts[:openrouter_judge] = v }
        o.on("--openrouter-judge-model M", "default: openai/gpt-5.5-pro") { |v| opts[:openrouter_judge_model] = v }
        o.separator ""
        o.separator "Env: OPENROUTER_API_KEY (required) · HB_AGENT_TIMEOUT=7200 · HB_RUNNER_IMAGE"
        o.separator "     HB_CPUS=8 · HB_MEMORY=16g · HB_PIDS=4096"
        o.separator "Exit: 0=all cells scored/pending · 1=usage/validation error · 2=one or more cells failed isolation"
      end.parse!(argv)
      opts
    rescue OptionParser::ParseError => e
      abort(e.message)
    end

    def validate!(opts)
      abort("--source <local clone path> is required") unless opts[:source]
      abort("--source path #{opts[:source]} is not a directory") unless File.directory?(opts[:source])
      abort("OPENROUTER_API_KEY must be set (passed into the runner for generation)") if ENV["OPENROUTER_API_KEY"].to_s.empty?
    end

    def select_profiles(agent)
      profiles = Slate.profiles
      return profiles unless agent

      picked = profiles.select { |p| p.id == agent }
      abort("unknown agent #{agent}; slate is #{profiles.map(&:id).join(", ")}") if picked.empty?
      picked
    end

    def build(opts)
      RunAll.new(
        runner: Run.new(restorer: GitRestore.new, spawn: IsolationExec.gen_exec,
                        reuse_resolver: Reuse.resolver),
        gate: Gate.new(exec: IsolationExec.gate_exec),
        judges: judges(opts),
        withhold_reference: opts[:withhold_reference]
      )
    end

    # The independent judges, keyed by the name recorded in results.json. The
    # dual-judge slate (maintainer decision 2026-07-09, superseding 2026-07-01):
    # fable-5 (local claude CLI, anthropic-family) + gpt-5.6-sol@xhigh (codex
    # CLI, openai-family) — both subscription, so judging costs no API balance.
    # gpt-5.5-pro via OpenRouter remains available behind --openrouter-judge
    # (off by default). Two judges is the slate; no third. Keys DERIVE from the
    # pinned judge model so results.json never claims a model that didn't judge.
    def judges(opts)
      j = {}
      if opts[:claude_judge]
        model = opts[:judge_model] || "claude-fable-5"
        j[model.sub(/\Aclaude-/, "")] =
          Judge.new(judge_fn: ClaudeJudge.judge_fn(bin: opts[:judge_bin], model: model), seeds: opts[:seeds])
      end
      if opts[:codex_judge]
        model = opts[:codex_judge_model] || CodexJudge::DEFAULT_MODEL
        effort = opts[:codex_judge_effort] || CodexJudge::DEFAULT_EFFORT
        j[model] = Judge.new(judge_fn: CodexJudge.judge_fn(model: model, effort: effort), seeds: opts[:seeds])
      end
      if opts[:openrouter_judge]
        j[opts[:openrouter_judge_model].split("/").last] =
          Judge.new(judge_fn: OpenRouterJudge.judge_fn(model: opts[:openrouter_judge_model]), seeds: opts[:seeds])
      end
      abort("no judges enabled (need --claude-judge, --codex-judge and/or --openrouter-judge)") if j.empty?
      j
    end

    def judge_efforts(opts)
      return {} unless opts[:codex_judge]

      { opts[:codex_judge_model] || CodexJudge::DEFAULT_MODEL =>
          opts[:codex_judge_effort] || CodexJudge::DEFAULT_EFFORT }
    end

    def write_and_report(outcome, opts)
      FileUtils.mkdir_p(opts[:out])
      path = File.join(opts[:out], "results.json")
      File.write(path, "#{JSON.pretty_generate(outcome.results)}\n")
      report(outcome, path)
      # Non-zero so CI / an agent caller notices cells that could not be isolated.
      # Pending (provider-limit) cells are an expected re-run state, not an error.
      exit(2) unless outcome.failed.empty?
    end

    def report(outcome, path)
      cells = outcome.results["cells"]
      warn "wrote #{path}: #{cells.size} scored cell(s), #{outcome.pending.size} pending, #{outcome.failed.size} failed"
      outcome.pending.each { |p| warn "  pending  #{p["agent_id"]}  #{p["task_id"]}  (#{p["reason"]})" }
      outcome.failed.each { |f| warn "  FAILED   #{f["agent_id"]}  #{f["task_id"]}  (#{f["reason"]})" }
      cells.each do |c|
        judges = (c["judges"] || {}).map { |name, j| "#{name}=#{j["mean"]}" }.join(" ")
        warn "  #{c["subset"]}  #{c["agent_id"]}  #{c["task_id"]}  gen=#{c["run_status"]}  " \
             "gate=#{c.dig("gate", "status")}  judge[#{judges.empty? ? "—" : judges}]"
      end
    end
  end
end

HiveBench::Driver.main(ARGV) if $PROGRAM_NAME == __FILE__
