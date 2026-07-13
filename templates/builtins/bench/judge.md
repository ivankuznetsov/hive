# Bench Judge Stage

Run this stage from the task folder after generation. It fills missing judge
scores and writes deliberation transcripts without changing scoring semantics.
Generation-time judge scores already carry the campaign seed count via
`hive_run.rb --seeds`; the rejudge here seeds only the judges it backfills.

Execute the `<!-- bench-stage-script -->` bash block below verbatim with
`bash` (extract it to a file and run it, or pipe it to `bash`). Do not
reimplement its steps, improvise around failing commands, or hand-write a
`<!-- WAITING -->`/`<!-- COMPLETE -->` marker yourself — every guard in this
stage lives in the script, and the script ends every path with exactly one
marker.

<!-- bench-stage-script -->
```bash
set -euo pipefail

STATE_FILE="judge.md"

# Scratch outputs are folded into the state file below; never leave them behind
# to be swept into hive-state commits.
trap 'rm -f .judge-campaign.out .judge-campaign.err .judge-args.out .judge-args.err .judge-precheck.out .judge-precheck.err .judge-rejudge.out .judge-rejudge.err .judge-deliberate.out .judge-deliberate.err .judge-delibmerge.out .judge-delibmerge.err .judge-validate.out .judge-validate.err' EXIT

write_waiting() {
  {
    printf '\n## Status\n\n'
    printf '%s\n\n' "$1"
    printf 'Retry: fix the condition above, then run `touch %s` after hive daemon debounce has elapsed.\n\n' "$STATE_FILE"
    printf '<!-- WAITING -->\n'
  } >>"$STATE_FILE"
}

write_complete() {
  {
    printf '\n## Status\n\n'
    printf 'Every pre-registered campaign cell is present with no unexpected cells; every non-empty-diff cell carries the configured judge slate at the requested sample count and reasoning effort, and the same slate appears in the adversarial deliberation transcript.\n\n'
    printf '<!-- COMPLETE -->\n'
  } >>"$STATE_FILE"
}

# Guarded: this substitution runs under `set -e`, and a cd failure before the
# marker helpers existed used to die marker-less.
REPO_ROOT="$(cd ../../../.. && pwd)" || {
  write_waiting "ERROR: could not resolve ../../../.. from $PWD (repo-root anchor failed)."
  exit 0
}

if [ ! -f "$REPO_ROOT/harness/hive_run.rb" ]; then
  write_waiting "ERROR: ../../../.. did not resolve to the hive-bench repo root; missing harness/hive_run.rb at $REPO_ROOT."
  exit 0
fi

if [ ! -f campaign.yml ]; then
  write_waiting "Missing campaign.yml. Restore the committed campaign pre-registration before judging."
  exit 0
fi

# One guarded extraction: a malformed campaign.yml must park WAITING, not kill
# the stage marker-less under `set -e`. Type-guard the three-line `read`
# extraction below: a multi-line source would silently feed a fragment into
# SEEDS (surfacing only as a cryptic OptionParser error).
ruby -ryaml -e '
  data = YAML.safe_load_file("campaign.yml")
  id = data.fetch("campaign_id").to_s
  abort("campaign_id must be a slug matching /\\A[a-z0-9][a-z0-9-]{0,63}\\z/; got #{id.inspect}") unless id.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
  abort("campaign_id v3-example is the unedited example id; pick a real campaign id") if id == "v3-example"
  source = data.fetch("source")
  abort("source must be a non-empty single-line string; got #{source.inspect}") unless source.is_a?(String) && !source.include?("\n") && !source.strip.empty?
  seeds = data.fetch("seeds")
  abort("seeds must be a positive integer; got #{seeds.inspect}") unless seeds.is_a?(Integer) && seeds.positive?
  judges = data.fetch("judges")
  abort("judges must be a mapping") unless judges.is_a?(Hash)
  unknown_judges = judges.keys.map(&:to_s) - %w[claude codex openrouter]
  abort("unknown judge backend(s): #{unknown_judges.join(", ")}") unless unknown_judges.empty?
  enabled = judges.reject { |_backend, config| config.nil? || config == false }
  abort("at least two judge backends must be enabled") if enabled.size < 2
  enabled.each do |backend, config|
    abort("judges.#{backend} must be a mapping or null") unless config.is_a?(Hash)
    model = config["model"]
    abort("judges.#{backend}.model must be a non-empty single-line string") unless model.is_a?(String) && !model.include?("\n") && !model.strip.empty?
  end
  judge_names = enabled.map do |backend, config|
    backend.to_s == "claude" ? config.fetch("model").sub(/\Aclaude-/, "") : config.fetch("model").split("/").last
  end
  abort("enabled judges must produce unique result keys; got #{judge_names.inspect}") unless judge_names.uniq.size == judge_names.size
  if enabled.key?("codex")
    effort = enabled.dig("codex", "reasoning_effort")
    abort("judges.codex.reasoning_effort must be a non-empty single-line string") unless effort.is_a?(String) && !effort.include?("\n") && !effort.strip.empty?
  end
  puts id
  puts source
  puts seeds
  puts enabled.key?("openrouter")
' >.judge-campaign.out 2>.judge-campaign.err || {
  write_waiting "$(cat .judge-campaign.err .judge-campaign.out)"
  exit 0
}
{ read -r CAMPAIGN_ID; read -r SOURCE; read -r SEEDS; read -r NEEDS_OPENROUTER; } <.judge-campaign.out
RESULTS="runs/$CAMPAIGN_ID/results.json"
DELIB="runs/$CAMPAIGN_ID/deliberation.json"

if [ ! -f "$REPO_ROOT/$RESULTS" ]; then
  write_waiting "Missing $RESULTS. Re-run generate before judge."
  exit 0
fi

ruby -ryaml -e '
  judges = YAML.safe_load_file("campaign.yml").fetch("judges")
  args = []
  if (claude = judges["claude"]).is_a?(Hash)
    args += ["--claude-judge", "--judge-model", claude.fetch("model").to_s]
  else
    args << "--no-claude-judge"
  end
  if (codex = judges["codex"]).is_a?(Hash)
    args += ["--codex-judge", "--codex-judge-model", codex.fetch("model").to_s,
             "--codex-judge-effort", codex.fetch("reasoning_effort").to_s]
  else
    args << "--no-codex-judge"
  end
  if (openrouter = judges["openrouter"]).is_a?(Hash)
    args += ["--openrouter-judge", "--openrouter-model", openrouter.fetch("model").to_s]
  else
    args << "--no-openrouter-judge"
  end
  puts args
' >.judge-args.out 2>.judge-args.err || {
  write_waiting "$(cat .judge-args.err .judge-args.out)"
  exit 0
}
mapfile -t JUDGE_ARGS <.judge-args.out

# pending/failed must be checked BEFORE the rejudge rewrite: rejudge output
# (Score#results) carries no pending/failed keys, so checking the rewritten
# file would always vacuously see [] and silently erase surviving entries
# under a COMPLETE.
ruby -rjson -e '
  data = JSON.parse(File.read(ARGV.fetch(0)))
  pending = data.fetch("pending", [])
  failed = data.fetch("failed", [])
  unless pending.empty? && failed.empty?
    abort("pending=#{pending.size} failed=#{failed.size} in #{ARGV.fetch(0)}; re-run generate until every cell is terminal before judging")
  end
' "$REPO_ROOT/$RESULTS" >.judge-precheck.out 2>.judge-precheck.err || {
  write_waiting "$(cat .judge-precheck.err .judge-precheck.out)"
  exit 0
}

if [ "$NEEDS_OPENROUTER" = "true" ] && [ -f "$HOME/.openrouter_key" ]; then
  sourced_key="$(cat "$HOME/.openrouter_key")" || {
    write_waiting "Failed to read $HOME/.openrouter_key; refusing to run with an empty judge key."
    exit 0
  }
  # An empty/whitespace key file must never clobber a valid key already in the
  # environment (cat exits 0 on an empty file).
  sourced_key="$(printf '%s' "$sourced_key" | tr -d '[:space:]')"
  if [ -n "$sourced_key" ]; then
    export OPENROUTER_API_KEY="$sourced_key"
  elif [ -z "${OPENROUTER_API_KEY:-}" ]; then
    write_waiting "$HOME/.openrouter_key is empty and OPENROUTER_API_KEY is unset; refusing to run without a judge key."
    exit 0
  fi
fi

if [ "$NEEDS_OPENROUTER" = "true" ] && [ -z "${OPENROUTER_API_KEY:-}" ]; then
  write_waiting "OPENROUTER_API_KEY is required by the configured OpenRouter judge."
  exit 0
fi

# Search dirs are the PER-CELL run dirs: rejudge/deliberate resolve artifacts at
# <search-dir>/<task_id>/<cell>, and generation writes them under
# runs/<campaign_id>/<candidate>--<task>/<task_id>/<cell>.
# --out .next + mv: backfilled judge scores exist ONLY in the campaign-root
# results.json (per-cell files never receive them), so an in-place rewrite of
# that sole copy could lose paid judge work if it crashed mid-write.
(cd "$REPO_ROOT" && ruby harness/rejudge.rb --source "$SOURCE" --results "$RESULTS" --out "$RESULTS.next" --seeds "$SEEDS" --only-missing --plan-source candidate "${JUDGE_ARGS[@]}" runs/"$CAMPAIGN_ID"/*--* \
  && mv "$RESULTS.next" "$RESULTS") \
  >.judge-rejudge.out 2>.judge-rejudge.err || {
  rm -f "$REPO_ROOT/$RESULTS.next"
  write_waiting "$(cat .judge-rejudge.err .judge-rejudge.out)"
  exit 0
}
# rejudge fails SOFT per judge (warn + exit 0), and the EXIT trap deletes the
# scratch stderr — keep the tail so a wall of judge failures (e.g. every
# OpenRouter call 403ing) can be reported next to the MISSING_JUDGES lines.
REJUDGE_ERR_TAIL="$(tail -n 15 .judge-rejudge.err)" || REJUDGE_ERR_TAIL=""

# Deliberate to a SCRATCH transcript and union below: deliberate.rb --out
# writes ONLY the newly deliberated cells, so pointing it at the transcript
# itself would destroy prior paid deliberations on a routine wall retry (and a
# zero-new-cell retry would wipe the file to cells:[]). --skip-done keeps
# retries from re-buying cells the transcript already covers.
(cd "$REPO_ROOT" && ruby harness/deliberate.rb --source "$SOURCE" --results "$RESULTS" --out "$DELIB.next" --min-disagreement 0 --plan-source candidate --skip-done "$DELIB" "${JUDGE_ARGS[@]}" runs/"$CAMPAIGN_ID"/*--*) \
  >.judge-deliberate.out 2>.judge-deliberate.err || {
  rm -f "$REPO_ROOT/$DELIB.next"
  write_waiting "$(cat .judge-deliberate.err .judge-deliberate.out)"
  exit 0
}

# Union old+new transcript cells by [task_id, agent_id] and replace via tmp+mv;
# the summary is recomputed over the union (mirrors DeliberateCli.summary —
# the scratch file's summary covers only the newly deliberated cells).
ruby -rjson -e '
  old_path, new_path = ARGV.fetch(0), ARGV.fetch(1)
  read = ->(path) { File.file?(path) ? JSON.parse(File.read(path)) : nil }
  fresh = read.(new_path) or abort("deliberate wrote no transcript at #{new_path}")
  old = read.(old_path)
  union = ((old ? old["cells"].to_a : []) + fresh["cells"].to_a)
          .each_with_object({}) { |t, acc| acc[[t["task_id"], t["agent_id"]]] = t }
          .values
  per_judge = Hash.new { |h, k| h[k] = [] }
  spreads = { before: [], after: [] }
  union.each do |t|
    js = t.fetch("judges", {}).values
    if js.size >= 2
      spreads[:before] << (js.map { |j| j["initial"] }.max - js.map { |j| j["initial"] }.min)
      finals = js.map { |j| j["final"] || j["initial"] }
      spreads[:after] << (finals.max - finals.min)
    end
    t.fetch("judges", {}).each { |name, j| per_judge[name] << j["delta"] if j["delta"] }
  end
  mean = ->(values) { values.empty? ? nil : (values.sum.to_f / values.size).round(3) }
  summary = {
    "cells" => union.size,
    "mean_revision_by_judge" => per_judge.transform_values { |d| (d.sum / d.size).round(3) },
    "mean_abs_revision_by_judge" => per_judge.transform_values { |d| (d.sum(&:abs) / d.size).round(3) },
    "mean_spread_before" => mean.(spreads[:before]),
    "mean_spread_after" => mean.(spreads[:after])
  }
  merged = (old || fresh).merge("cells" => union, "summary" => summary)
  File.write("#{old_path}.merged", "#{JSON.pretty_generate(merged)}\n")
  File.rename("#{old_path}.merged", old_path)
' "$REPO_ROOT/$DELIB" "$REPO_ROOT/$DELIB.next" >.judge-delibmerge.out 2>.judge-delibmerge.err || {
  rm -f "$REPO_ROOT/$DELIB.next" "$REPO_ROOT/$DELIB.merged"
  write_waiting "Deliberation transcript union failed: $(cat .judge-delibmerge.err .judge-delibmerge.out)"
  exit 0
}
rm -f "$REPO_ROOT/$DELIB.next"

ruby -ryaml -rjson -e '
  data = JSON.parse(File.read(ARGV.fetch(0)))
  delib = File.file?(ARGV.fetch(1)) ? JSON.parse(File.read(ARGV.fetch(1))) : { "cells" => [] }
  campaign = YAML.safe_load_file("campaign.yml")
  exclusions = campaign.fetch("exclusions", []).map { |item| [item.fetch("task").to_s, item.fetch("candidate").to_s] }
  expected = campaign.fetch("tasks").flat_map { |task| campaign.fetch("candidates").map { |candidate| [task.to_s, candidate.to_s] } } - exclusions
  cells = data.fetch("cells", [])
  by_key = cells.to_h { |cell| [[cell["task_id"].to_s, cell["agent_id"].to_s], cell] }
  # The campaign judge slate, validated BY NAME (the harness dual-judge
  # defaults: run_all.rb judges() and the rejudge.rb CLI both derive these keys
  # from the pinned judge models). Counting judges instead would let stale keys
  # from a results file spanning a slate change pass for the current slate.
  # Judges fail soft per cell during generation, so a partial-slate cell is a
  # routine backfill target, not a success.
  judge_configs = campaign.fetch("judges").reject { |_backend, config| config.nil? || config == false }
  judge_slate = judge_configs.map do |backend, config|
    backend == "claude" ? config.fetch("model").sub(/\Aclaude-/, "") : config.fetch("model").split("/").last
  end
  expected_efforts = judge_configs.to_h do |backend, config|
    name = backend == "claude" ? config.fetch("model").sub(/\Aclaude-/, "") : config.fetch("model").split("/").last
    [name, backend == "codex" ? config.fetch("reasoning_effort") : "unspecified"]
  end
  deliberated = delib.fetch("cells", []).to_a.to_h { |t| [[t["task_id"].to_s, t["agent_id"].to_s], t] }
  problems = []
  expected.each do |task, candidate|
    cell = by_key[[task, candidate]]
    if cell.nil?
      problems << "MISSING_CELL #{candidate} #{task}"
      next
    end
    next if cell["run_status"] == "empty_diff"
    missing_judges = judge_slate - cell.fetch("judges", {}).keys
    unless missing_judges.empty?
      problems << "MISSING_JUDGES #{candidate} #{task} (missing: #{missing_judges.join(",")}; have: #{cell.fetch("judges", {}).keys.sort.join(",")})"
      next
    end
    judge_slate.each do |judge|
      record = cell.fetch("judges").fetch(judge)
      samples = record["sample_count"] || Array(record["scores"]).size
      samples = 1 if samples.to_i.zero? && record.key?("mean")
      problems << "UNDERSAMPLED_JUDGE #{candidate} #{task} #{judge} (have #{samples}, need #{campaign.fetch("seeds")})" if samples.to_i < campaign.fetch("seeds")
      effort = record.fetch("reasoning_effort", "unspecified")
      problems << "JUDGE_EFFORT_MISMATCH #{candidate} #{task} #{judge} (have #{effort}, need #{expected_efforts.fetch(judge)})" unless effort == expected_efforts.fetch(judge)
    end
    # deliberate.rb silently drops cells it cannot resolve (e.g. a task_id
    # missing from the corpus); COMPLETE must not claim transcript coverage it
    # does not have.
    transcript = deliberated[[task, candidate]]
    unless transcript
      problems << "MISSING_DELIBERATION #{candidate} #{task} (dual-judged but absent from #{ARGV.fetch(1)})"
      next
    end
    missing_deliberation_judges = judge_slate - transcript.fetch("judges", {}).keys
    unless missing_deliberation_judges.empty?
      problems << "MISSING_DELIBERATION_JUDGES #{candidate} #{task} (missing: #{missing_deliberation_judges.join(",")})"
    end
    judge_slate.each do |judge|
      next unless transcript.fetch("judges", {}).key?(judge)

      effort = transcript.dig("judges", judge, "reasoning_effort") || "unspecified"
      problems << "DELIBERATION_EFFORT_MISMATCH #{candidate} #{task} #{judge} (have #{effort}, need #{expected_efforts.fetch(judge)})" unless effort == expected_efforts.fetch(judge)
    end
  end
  # A results cell outside the pre-registered matrix means campaign.yml was
  # amended mid-campaign (matrix shrunk or exclusions grown after generation);
  # refuse to pass de-registered paid cells silently into publish.
  by_key.each_key do |task, candidate|
    next if expected.include?([task, candidate])
    problems << "UNEXPECTED_CELL #{candidate} #{task} (not in the pre-registered campaign matrix)"
  end
  unless problems.empty?
    problems.each { |line| puts line }
    exit 2
  end
' "$REPO_ROOT/$RESULTS" "$REPO_ROOT/$DELIB" >.judge-validate.out 2>.judge-validate.err || {
  err_tail=""
  if [ -n "$REJUDGE_ERR_TAIL" ]; then
    err_tail="$(printf '\n\nrejudge stderr tail (per-judge failures are soft; this is the only record of their cause):\n%s' "$REJUDGE_ERR_TAIL")"
  fi
  write_waiting "$(cat .judge-validate.err .judge-validate.out)${err_tail}"
  exit 0
}

write_complete
```
