# frozen_string_literal: true

# Executed in a child with only the selected (canonical or installed) harness
# on its load path. Providers are deterministic local seams and fake CLIs.
require "json"
require "yaml"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "run_all"
require "merge_results"
require "lib/corpus"

module BenchEvidenceLifecycle
  module_function

  def check(condition, message)
    raise message unless condition
  end

  def command(*argv, **options)
    out, err, status = Open3.capture3(*argv, **options)
    check(status.success?, "#{argv.first(2).join(' ')} failed: #{out}#{err}")
    out
  end

  def run
    harness = File.dirname($LOADED_FEATURES.find { |file| file.end_with?("/run_all.rb") })
    Dir.mktmpdir("bench-evidence-lifecycle") do |root|
      source = File.join(root, "source")
      FileUtils.mkdir_p(source)
      command("git", "init", "-q", source)
      command("git", "-C", source, "config", "user.name", "Bench Fixture")
      command("git", "-C", source, "config", "user.email", "bench@example.invalid")
      File.write(File.join(source, "file"), "base\n")
      command("git", "-C", source, "add", "file")
      command("git", "-C", source, "commit", "-qm", "base")
      base = command("git", "-C", source, "rev-parse", "HEAD").strip
      corpus = File.join(root, "corpus")
      statuses = { "success" => :ok, "empty" => :ok, "timeout" => :timeout, "failed" => :error }
      statuses.each_key do |task|
        entry = File.join(corpus, task)
        FileUtils.mkdir_p(entry)
        File.write(File.join(entry, "plan.md"), "Change file unless empty.\n")
        File.write(File.join(entry, "manifest.yml"), YAML.dump(
          "task_id" => task, "source" => { "base_commit" => base }, "spec" => { "plan" => "plan.md" }
        ))
      end
      entries = HiveBench::Corpus.load(root: corpus, checkout_source: source)
      profile = Struct.new(:id, :model).new("A", "model")
      gate = Object.new
      def gate.call(**) = HiveBench::Gate::Result.new(status: :pass, subset: "gated", reason: "fixture", details: {})
      # Gate specs opt cells into the gate seam, including the observed empty patch.
      entries.each do |entry|
        FileUtils.mkdir_p(File.join(entry["entry_dir"], "gate"))
        File.write(File.join(entry["entry_dir"], "gate", "gate.yml"), "fixture: true\n")
      end
      calls = 0
      spawn = lambda do |cwd:, **|
        task = File.basename(File.dirname(File.dirname(cwd)))
        calls += 1
        File.write(File.join(cwd, "file"), "changed\n") unless task == "empty"
        { status: statuses.fetch(task), stdout: "", stderr: "", usage: { cost: 1.0 } }
      end
      judge = ->(score) { HiveBench::Judge.new(judge_fn: ->(**) { { score: score, reason: "fixture" } }, seeds: 1) }
      driver = lambda do |out, slate, subset|
        HiveBench::RunAll.new(runner: HiveBench::Run.new(spawn: spawn), gate: gate,
                              judges: slate, withhold_reference: true)
          .call(entries: subset, profiles: [ profile ], out_root: out, corpus_version: "fixture").results
      end
      old_runs = File.join(root, "old")
      first = driver.call(old_runs, { "X" => judge.call(2.0) }, entries)
      check(calls == 4, "each matrix cell must generate once")
      summary = first.dig("agents", "A")
      check(summary.dig("coverage", "eligible_executions") == 2, "only success and empty are eligible")
      check(summary.dig("judged", "scored_cells") == 1, "empty must not invent a judge score")
      check(summary.dig("gated", "total") == 2, "empty preserves normal gate behavior")
      check(summary.dig("diagnostics", "judged", "scored_cells") == 2, "partials remain diagnostic")
      # A selected legacy artifact is rejudged without generation or inherited gate evidence.
      legacy = first.fetch("cells").find { |cell| cell["task_id"] == "timeout" }
      legacy.delete("generation_id")
      legacy.delete("record_kind")
      legacy["gate"].delete("evidence_binding")
      parked = { "task_id" => "parked", "agent_id" => "A", "generation_id" => "parked", "run_status" => "limit_hit",
                 "mode" => "fresh", "efficiency" => { "cost_usd" => 5.0 } }
      first.merge!("pending" => [ parked ], "failed" => [], "custom" => { "preserved" => true }, "schema_version" => 77)
      original_buckets = first.slice("pending", "failed", "custom", "schema", "schema_version")
      input = File.join(root, "results.json")
      File.write(input, JSON.generate(first))
      fake_bin = File.join(root, "bin")
      FileUtils.mkdir_p(fake_bin)
      log = File.join(root, "judge.calls")
      File.write(File.join(fake_bin, "claude"), "#!/bin/sh\ncat >/dev/null\nprintf 'call\\n' >> \"$BENCH_FIXTURE_CALLS\"\nprintf '%s\\n' '{\"score\":9.0,\"reason\":\"fixture\",\"discussion\":\"checked\"}'\n")
      FileUtils.chmod(0o755, File.join(fake_bin, "claude"))
      env = { "PATH" => "#{fake_bin}:#{ENV['PATH']}", "BENCH_FIXTURE_CALLS" => log }
      backfill = [ RbConfig.ruby, File.join(harness, "rejudge.rb"), "--source", source, "--corpus", corpus,
                  "--results", input, "--out", input, "--only-missing", "--seeds", "1", "--withhold-reference",
                  "--judge-model", "claude-Y", "--no-openrouter-judge", "--no-codex-judge", old_runs ]
      2.times { command(env, *backfill) }
      backfilled = JSON.parse(File.read(input))
      check(File.readlines(log).size == 3, "only-missing must backfill each nonempty current artifact once")
      check(backfilled.slice(*original_buckets.keys) == original_buckets, "rejudge must preserve metadata and buckets")
      check(calls == 4, "legacy adoption must not regenerate")
      check(backfilled.dig("agents", "A", "judged", "mean_quality", "Y") == 9.0, "eligible backfill must rank")
      check(backfilled.fetch("rejudging_needed").any? { |item| item["task_id"] == "timeout" && item["reasons"].include?("fresh gating required") }, "legacy gate needs fresh gating")
      check(backfilled.fetch("generation_history").size == 1, "legacy evaluations remain in history")
      replacement_runs = File.join(root, "replacement")
      replacement = driver.call(replacement_runs, { "Y" => judge.call(9.0) }, entries.select { |entry| entry["task_id"] == "success" })
      a = first.fetch("cells").find { |cell| cell["task_id"] == "success" }
      b = replacement.fetch("cells").first
      check(a["generation_id"] != b["generation_id"] && a["artifact_binding"] == b["artifact_binding"], "identical-byte replacement must rotate identity")
      replacement_path = File.join(root, "replacement.json")
      File.write(replacement_path, JSON.generate(replacement))
      command(RbConfig.ruby, File.join(harness, "merge_results.rb"), "--out", input, input, replacement_path)
      merged = JSON.parse(File.read(input))
      active = merged.fetch("cells").find { |cell| cell["task_id"] == "success" }
      check(active == b, "replacement must carry only its own judges, gate and telemetry")
      command(RbConfig.ruby, File.join(harness, "merge_results.rb"), "--out", input, input, input)
      repeated = JSON.parse(File.read(input))
      check(merged["agents"] == repeated["agents"] && merged["generation_history"] == repeated["generation_history"], "repeat publication must not multiply cost/history")
      check(repeated.dig("agents", "A", "efficiency", "total_cost_usd") == 9.0, "operational totals retain parked/partial cost once")
      puts JSON.generate("eligible" => 2, "ranked_judged" => 1, "gated" => 2, "diagnostic_judged" => 2,
                         "generations" => calls, "backfill_calls" => 3, "history" => repeated["generation_history"].size)
    end
  end
end

BenchEvidenceLifecycle.run if $PROGRAM_NAME == __FILE__
