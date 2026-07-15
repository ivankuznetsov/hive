# frozen_string_literal: true

# Planner/executor pipeline pass: each cell is a (planner, executor) PAIR — the
# planner authors the plan from idea+brainstorm, the executor implements it, and
# the executor's diff is dual-judged. Reuses RunAll's scoring/judging (the
# Pipeline cell is shaped like a Run cell), so only the runner differs.
#
#   OPENROUTER_API_KEY=… ruby harness/pipeline_run.rb --source <clone> [--pair glm-5.2->kimi-k2.7]
$LOAD_PATH.unshift(__dir__) unless $LOAD_PATH.include?(__dir__)

require "optparse"
require "fileutils"
require "json"
require "run_all"
require "lib/pipeline"
require "lib/git_restore"
require "lib/isolation_exec"
require "lib/corpus"
require "lib/claude_judge"
require "lib/openrouter_judge"
require "profiles/slate"

module HiveBench
  # Thin driver: builds a Pipeline-backed runner and hands it to RunAll.
  module PipelineDriver
    module_function

    def main(argv)
      opts = parse(argv)
      validate!(opts)
      entries = Corpus.load(root: opts[:corpus], checkout_source: opts[:source])
      abort("no corpus entries under #{opts[:corpus]}") if entries.empty?
      pairs = select_pairs(opts[:pair])

      outcome = RunAll.new(runner: pipeline_runner, gate: Gate.new(exec: IsolationExec.gate_exec),
                           judges: Driver.judges(opts), withhold_reference: opts[:withhold_reference])
                      .call(entries: entries, profiles: pairs, out_root: opts[:out],
                            corpus_version: opts[:corpus_version])
      write_and_report(outcome, opts)
    end

    # Pipeline needs two spawn seams: an identity-framed planner spawn (the
    # pipeline supplies the full planner prompt) and the normal executor spawn.
    def pipeline_runner
      pipeline = Pipeline.new(plan_spawn: IsolationExec.gen_exec(frame: ->(p) { p }),
                              exec_spawn: IsolationExec.gen_exec, restorer: GitRestore.new)
      lambda do |entry:, profile:, out_dir:|
        pipeline.call(entry: entry, planner: profile.planner, executor: profile.executor,
                      pair_id: profile.id, out_dir: out_dir)
      end
    end

    def parse(argv)
      opts = { corpus: "corpus", out: "runs", source: nil, pair: nil, seeds: 1, corpus_version: "v1",
               withhold_reference: true, claude_judge: true, judge_bin: "claude", judge_model: nil,
               openrouter_judge: true, openrouter_judge_model: "openai/gpt-5.5-pro" }
      OptionParser.new do |o|
        o.banner = "Usage: OPENROUTER_API_KEY=… ruby harness/pipeline_run.rb --source <clone> [opts]"
        o.on("--source PATH", "local clone restored at base_commit (required)") { |v| opts[:source] = v }
        o.on("--corpus DIR") { |v| opts[:corpus] = v }
        o.on("--out DIR") { |v| opts[:out] = v }
        o.on("--pair ID", "run only this pair, e.g. glm-5.2->kimi-k2.7") { |v| opts[:pair] = v }
        o.on("--seeds N", Integer) { |v| opts[:seeds] = v }
        o.on("--corpus-version V") { |v| opts[:corpus_version] = v }
        o.on("--[no-]withhold-reference") { |v| opts[:withhold_reference] = v }
        o.on("--[no-]openrouter-judge") { |v| opts[:openrouter_judge] = v }
      end.parse!(argv)
      opts
    rescue OptionParser::ParseError => e
      abort(e.message)
    end

    def validate!(opts)
      abort("--source <local clone path> is required") unless opts[:source]
      abort("--source path #{opts[:source]} is not a directory") unless File.directory?(opts[:source])
      abort("OPENROUTER_API_KEY must be set") if ENV["OPENROUTER_API_KEY"].to_s.empty?
    end

    def select_pairs(id)
      pairs = Slate.pipelines
      return pairs unless id

      picked = pairs.select { |p| p.id == id }
      abort("unknown pair #{id}; pairs are #{pairs.map(&:id).join(", ")}") if picked.empty?
      picked
    end

    def write_and_report(outcome, opts)
      FileUtils.mkdir_p(opts[:out])
      path = File.join(opts[:out], "results.json")
      File.write(path, "#{JSON.pretty_generate(outcome.results)}\n")
      warn "wrote #{path}: #{outcome.results["cells"].size} cell(s), #{outcome.pending.size} pending, #{outcome.failed.size} failed"
      outcome.results["cells"].each do |c|
        judges = (c["judges"] || {}).map { |n, j| "#{n}=#{j["mean"]}" }.join(" ")
        warn "  #{c["agent_id"]}  #{c["task_id"]}  gen=#{c["run_status"]}  judge[#{judges}]"
      end
      exit(2) unless outcome.failed.empty?
    end
  end
end

HiveBench::PipelineDriver.main(ARGV) if $PROGRAM_NAME == __FILE__
