# Bench Generate Stage

Run this stage from the task folder. It refuses to spend tokens until
`campaign.yml` exists, is tracked, is clean, and validates against the v3
campaign contract. On success it merges every per-cell result into
`runs/<campaign_id>/results.json`, the file the judge and publish stages
consume.

Execute the `<!-- bench-stage-script -->` bash block below verbatim with
`bash` (extract it to a file and run it, or pipe it to `bash`). Do not
reimplement its steps, improvise around failing commands, or hand-write a
`<!-- WAITING -->`/`<!-- ERROR -->`/`<!-- COMPLETE -->` marker yourself —
every guard in this stage lives in the script, and the script ends every path
with exactly one marker. Do not end the stage while the script is running. If
the command tool reports `Script running with cell ID ...`, call
`functions.wait` and keep waiting until it completes; if it returns a session
id, use the matching session wait operation until exit. A yielded shell is not
a completed benchmark stage.

<!-- bench-stage-script -->
```bash
set -euo pipefail

STATE_FILE="generate.md"

# Scratch outputs are folded into the state file below; never leave them behind
# to be swept into hive-state commits (.generate-commands carries absolute
# source paths).
trap 'rm -f .generate-validate.out .generate-validate.err .generate-campaign.out .generate-campaign.err .generate-commands .generate-commands.err .generate-cmd-*.err .generate-run.err .generate-outcome.out .generate-outcome.err .generate-merge.out .generate-merge.err' EXIT

write_waiting() {
  {
    printf '\n## Status\n\n'
    printf '%s\n\n' "$1"
    printf 'Retry: fix the condition above, then run `touch %s` after hive daemon debounce has elapsed.\n\n' "$STATE_FILE"
    printf '<!-- WAITING -->\n'
  } >>"$STATE_FILE"
}

write_limits_reached() {
  retry_after="$(ruby -rtime -e '
    seconds = Integer(ENV.fetch("HIVE_LIMITS_RETRY_COOLDOWN_SEC", "3600"), exception: false)
    seconds = 3600 unless seconds&.positive?
    puts (Time.now.utc + seconds).iso8601
  ')"
  {
    printf '\n## Status\n\n'
    printf '%s\n\n' "$1"
    printf 'Hive will retry this stage after the provider cooldown at %s.\n\n' "$retry_after"
  } >>"$STATE_FILE"
  # Stage agents intentionally run with RubyGems environment scrubbed. Load the
  # marker implementation from the campaign's immutable source runtime instead
  # of whichever released hive-cli gem happens to be installed on the host.
  ruby -I"$SOURCE/lib" -rhive/markers -e '
    Hive::Markers.set(
      ARGV.fetch(0),
      :error,
      "reason" => "limits_reached",
      "message" => "benchmark candidate or judge hit provider quota",
      "retry_after" => ARGV.fetch(1)
    )
  ' "$STATE_FILE" "$retry_after"
}

write_complete() {
  {
    printf '\n## Status\n\n'
    printf '%s\n\n' "$1"
    printf '<!-- COMPLETE -->\n'
  } >>"$STATE_FILE"
}

# Guarded: this substitution runs under `set -e`, and a cd failure before the
# marker helpers existed used to die marker-less.
REPO_ROOT="$(cd ../../../.. && pwd)" || {
  write_waiting "ERROR: could not resolve ../../../.. from $PWD (repo-root anchor failed)."
  exit 0
}
BENCH_ROOT="$REPO_ROOT/.hive-state/bench-runtime"

if [ ! -f "$BENCH_ROOT/harness/hive_run.rb" ]; then
  write_waiting "ERROR: the packaged bench runtime is missing at $BENCH_ROOT. Re-run hive init --workflow bench to install it."
  exit 0
fi

if [ ! -f campaign.yml ]; then
  write_waiting "Missing campaign.yml. Copy campaign.yml.example into this task folder, edit it, and commit it."
  exit 0
fi

if ! git ls-files --error-unmatch campaign.yml >/dev/null 2>&1; then
  write_waiting "campaign.yml exists but is not committed in the hive-state checkout. Add and commit it before generation."
  exit 0
fi

# Fail closed: a git error while checking cleanliness must not read as "clean".
campaign_dirty="$(git status --porcelain -- campaign.yml)" || {
  write_waiting "git status failed while checking campaign.yml cleanliness; refusing to treat it as clean."
  exit 0
}
if [ -n "$campaign_dirty" ]; then
  write_waiting "campaign.yml has uncommitted changes. Commit the final pre-registration before generation."
  exit 0
fi

ruby -ryaml -rjson -e '
  repo = ARGV.fetch(0)
  runtime = ARGV.fetch(1)
  require File.join(runtime, "harness/lib/campaign_contract")
  data = YAML.safe_load_file("campaign.yml")
  HiveBench::CampaignContract.validate_generation!(data, repo_root: repo)
  HiveBench::CampaignContract.verify_generation_network!(data)
' "$REPO_ROOT" "$BENCH_ROOT" >.generate-validate.out 2>.generate-validate.err || {
  write_waiting "$(cat .generate-validate.err .generate-validate.out)"
  exit 0
}

ruby -ryaml -e '
  runtime = ARGV.fetch(0)
  repo = ARGV.fetch(1)
  require File.join(runtime, "harness/lib/campaign_contract")
  data = YAML.safe_load_file("campaign.yml")
  puts data.fetch("campaign_id")
  puts HiveBench::CampaignContract.source(data, repo_root: repo)
  puts data.fetch("corpus_version")
  require File.join(runtime, "harness/profiles/candidates")
  puts HiveBench::CampaignContract.campaign_requires_openrouter?(data)
' "$BENCH_ROOT" "$REPO_ROOT" >.generate-campaign.out 2>.generate-campaign.err || {
  write_waiting "$(cat .generate-campaign.err .generate-campaign.out)"
  exit 0
}
{ read -r CAMPAIGN_ID; read -r SOURCE; read -r CORPUS_VERSION; read -r NEEDS_OPENROUTER; } <.generate-campaign.out

ruby -ryaml -rshellwords -rjson -e '
  repo = ARGV.fetch(0)
  runtime = ARGV.fetch(1)
  require File.join(runtime, "harness/profiles/candidates")
  require File.join(runtime, "harness/lib/campaign_contract")
  data = YAML.safe_load_file("campaign.yml")
  terminal = %w[generated empty_diff].freeze
  require_successful_execution = data["require_successful_execution"] == true
  exclusions = data.fetch("exclusions", []).map { |item| [item.fetch("task").to_s, item.fetch("candidate").to_s] }
  # A cell is BOUGHT once generation reached a terminal status — or once ANY
  # candidate diff was captured on disk, regardless of which bucket
  # (pending[]/failed[]/cells[]) the run parked the cell in: hive_run.rb
  # buckets judge walls in pending[] but non-limit judge exhaustion and
  # post-generation errors in failed[], and its driver starts by rm-rf-ing the
  # work tree, so re-running would destroy the paid diff either way. Such
  # cells are reported by the outcome check below for judge backfill, never
  # regenerated (remove the cell dir manually to force a true regeneration).
  # A parse error on an EXISTING result file fails closed (abort -> WAITING):
  # File.write is not atomic, and a truncated file must not read as "never ran".
  bought = lambda do |out_dir|
    path = File.join(repo, out_dir, "results.json")
    begin
      result = JSON.parse(File.read(path))
    rescue Errno::ENOENT
      result = nil
    rescue JSON::ParserError => e
      abort("#{path} exists but does not parse (#{e.message[0, 120]}); refusing to regenerate a possibly-paid cell. Inspect it (and remove the cell dir) manually if the cell is truly dead.")
    end
    if result
      cell = (result["cells"] || []).first
      next true if cell && terminal.include?(cell["run_status"])
    end
    next false if require_successful_execution

    !Dir.glob(File.join(repo, out_dir, "*", "*", "target", "candidate.patch")).empty?
  end
  hive_timeout = data.fetch("timeouts", {})["hive_seconds"]
  source = HiveBench::CampaignContract.source(data, repo_root: repo)
  judge_args = HiveBench::CampaignContract.judge_arguments(
    data.fetch("judges"), openrouter_model_flag: "--openrouter-judge-model"
  )
  data.fetch("tasks").each do |task|
    data.fetch("candidates").each do |candidate|
      next if exclusions.include?([task.to_s, candidate.to_s])
      # One out dir per cell: hive_run.rb OVERWRITES results.json per
      # invocation, so a shared campaign dir would keep only the last cell.
      out = File.join("runs", data.fetch("campaign_id").to_s, "#{candidate}--#{task}")
      next if bought.call(out) # a bought cell is never re-bought
      args = [
        "ruby", File.join(runtime, "harness/hive_run.rb"),
        "--source", source,
        "--candidate", candidate.to_s,
        "--task", task.to_s,
        "--out", out,
        "--seeds", data.fetch("seeds").to_s,
        "--corpus-version", data.fetch("corpus_version").to_s
      ]
      args.concat(judge_args)
      env = ["env"]
      # Timeout comes from the pre-registered contract (timeouts.hive_seconds);
      # when unset, harness defaults apply, as campaign.yml.example documents.
      env << "HB_HIVE_TIMEOUT=#{hive_timeout}" if hive_timeout
      isolation = data.fetch("isolation", {})
      env << "HB_REQUIRE_SEALED_AGENT_RUNTIME=1" if isolation["sealed_agent_runtime"] == true
      if isolation["require_provider_egress"] == true
        env << "HB_REQUIRE_EGRESS_ALLOWLIST=1"
        env << "HB_GEN_NETWORK=#{isolation.fetch("docker_network")}"
        env << "HB_GEN_HTTPS_PROXY=#{isolation.fetch("https_proxy")}"
      end
      profile = HiveBench::Candidates.by_id(candidate.to_s)
      if profile
        codex_models = []
        codex_models << profile.codex_model if profile.respond_to?(:codex_model)
        codex_models.concat((profile.codex_models || {}).values) if profile.respond_to?(:codex_models)
        if codex_models.compact.any? { |model| model.to_s.start_with?("gpt-5.6-") }
          # The Sol image carries Codex >= 0.144 and the Grok CLI, so it is the
          # combined runner for Sol/Terra + Grok mixed workflows as well.
          env << "HB_RUNNER_IMAGE=hive-bench-runner:sol"
        elsif profile.grok_model
          env << "HB_RUNNER_IMAGE=hive-bench-runner:grok"
        end
      end
      puts Shellwords.join(env + args)
    end
  end
' "$REPO_ROOT" "$BENCH_ROOT" >.generate-commands 2>.generate-commands.err || {
  write_waiting "$(cat .generate-commands.err)"
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
  write_waiting "OPENROUTER_API_KEY is required by an enabled OpenRouter route or Pi/OpenCode-backed candidate."
  exit 0
fi

generate_status=0
: >.generate-run.err
generate_pids=()
generate_errs=()
generate_commands=()
generate_index=0
while IFS= read -r command; do
  generate_index=$((generate_index + 1))
  err_path=".generate-cmd-${generate_index}.err"
  generate_errs+=("$err_path")
  generate_commands+=("$command")
  # </dev/null: a stdin-reading descendant must not swallow queued command lines.
  # bash -c, not -lc: the stage exports everything the harness needs, and a
  # login profile would feed unattributable noise/failures into per-cell status.
  # Stderr is captured per cell so a pre-spend abort (e.g. a missing judge
  # key) can be surfaced next to the "missing" cell it caused.
  (cd "$REPO_ROOT" && bash -c "$command" </dev/null) 2>"$err_path" &
  generate_pids+=("$!")
done <.generate-commands

# Start the complete matrix before waiting so independent benchmark cells use
# the provider allowance concurrently. Still reap every child and retain each
# cell's diagnostics before classifying the campaign result.
for index in "${!generate_pids[@]}"; do
  set +e
  wait "${generate_pids[$index]}"
  status=$?
  set -e
  err_path="${generate_errs[$index]}"
  command="${generate_commands[$index]}"
  cat "$err_path" >&2
  { printf -- '--- exit %s: %s\n' "$status" "$command"; tail -n 5 "$err_path"; } >>.generate-run.err
  if [ "$status" -ne 0 ]; then
    generate_status="$status"
  fi
done

run_note=""
if [ "$generate_status" -ne 0 ]; then
  run_note="One or more generation commands exited nonzero; per-cell results below are authoritative. "
fi

set +e
ruby -ryaml -rjson -e '
  repo = ARGV.fetch(0)
  data = YAML.safe_load_file("campaign.yml")
  terminal = %w[generated empty_diff].freeze
  require_successful_execution = data["require_successful_execution"] == true
  exclusions = data.fetch("exclusions", []).map { |item| [item.fetch("task").to_s, item.fetch("candidate").to_s] }
  bad = []
  quota_only = true
  data.fetch("tasks").each do |task|
    data.fetch("candidates").each do |candidate|
      next if exclusions.include?([task.to_s, candidate.to_s])
      dir = File.join(repo, "runs", data.fetch("campaign_id").to_s, "#{candidate}--#{task}")
      begin
        result = JSON.parse(File.read(File.join(dir, "results.json")))
      rescue Errno::ENOENT
        bad << "#{candidate}/#{task}: missing"
        quota_only = false
        next
      rescue JSON::ParserError => e
        bad << "#{candidate}/#{task}: unreadable results.json (#{e.message[0, 80]})"
        quota_only = false
        next
      end
      cell = (result["cells"] || []).first
      status = cell ? cell["run_status"] : "missing"
      pending = result.fetch("pending", [])
      failed = result.fetch("failed", [])
      if terminal.include?(status)
        # A terminal cell may only pass with clean pending/failed buckets: a
        # contradictory result must never merge and reach COMPLETE.
        next if pending.empty? && failed.empty?
        bad << "#{candidate}/#{task}: #{status} but per-cell pending=#{pending.size} failed=#{failed.size} are nonempty — contradictory result; inspect #{dir}"
        quota_only = false
        next
      end
      patches = Dir.glob(File.join(dir, "*", "*", "target", "candidate.patch"))
      if !require_successful_execution && cell && pending.empty? && failed.empty? && patches.any? { |path| File.size?(path) }
        # The generation outcome remains honest (for example execute_failed),
        # but a non-empty paid diff is sufficient input for the judge stage.
        # Merge it into the campaign root below; judge will backfill the exact
        # configured slate without re-running the candidate.
        next
      end
      if require_successful_execution
        status = "#{status} — campaign requires successful execution"
      elsif !patches.empty?
        # Applies to every bucket a walled cell can land in (pending, failed,
        # or a non-terminal cells[] record): the diff is paid for either way.
        status = "judges_pending (was: #{status}) — diff already captured; do NOT regenerate. Backfill judges with harness/rejudge.rb against the campaign-root runs/#{data.fetch("campaign_id")}/results.json only — never point rejudge --out at this cell'"'"'s results.json (that erases pending[] and re-arms regeneration)"
      end
      reasons = (pending + failed).filter_map { |entry| entry["reason"] }
      bad << "#{candidate}/#{task}: #{status}#{reasons.empty? ? "" : " — #{reasons.join("; ")}"}"
      quota_only &&= !pending.empty? && failed.empty?
    end
  end
  unless bad.empty?
    puts "unfinished=#{bad.size}"
    bad.each { |line| puts "UNFINISHED #{line}" }
    exit(quota_only ? 75 : 2)
  end
' "$REPO_ROOT" >.generate-outcome.out 2>.generate-outcome.err
outcome_status=$?
set -e
if [ "$outcome_status" -ne 0 ]; then
  err_tail=""
  if [ -s .generate-run.err ]; then
    err_tail="$(printf '\n\nGeneration command stderr tails:\n%s' "$(tail -n 40 .generate-run.err)")"
  fi
  outcome_message="${run_note}$(cat .generate-outcome.err .generate-outcome.out)${err_tail}"
  if [ "$outcome_status" -eq 75 ]; then
    write_limits_reached "$outcome_message"
  else
    write_waiting "$outcome_message"
  fi
  exit 0
fi

# Judge and publish consume ONE campaign-root results.json; hive_run.rb only
# writes per-cell files, so merging them here is the handoff. An EXISTING
# campaign root is merged in FIRST: rejudge backfills live only there, and
# rebuilding purely from per-cell files would silently discard every
# backfilled judge score (per-cell files listed after it stay authoritative
# for run_status/gate while judges union). Written via .next + mv so a crash
# mid-write can never truncate the only copy of paid judge work.
merge_inputs=()
if [ -f "$REPO_ROOT/runs/$CAMPAIGN_ID/results.json" ]; then
  merge_inputs+=("runs/$CAMPAIGN_ID/results.json")
fi
(cd "$REPO_ROOT" && ruby "$BENCH_ROOT/harness/merge_results.rb" --out "runs/$CAMPAIGN_ID/results.json.next" --corpus-version "$CORPUS_VERSION" "${merge_inputs[@]}" runs/"$CAMPAIGN_ID"/*--*/results.json \
  && mv "runs/$CAMPAIGN_ID/results.json.next" "runs/$CAMPAIGN_ID/results.json") \
  >.generate-merge.out 2>.generate-merge.err || {
  rm -f "$REPO_ROOT/runs/$CAMPAIGN_ID/results.json.next"
  write_waiting "${run_note}Per-cell merge failed: $(cat .generate-merge.err .generate-merge.out)"
  exit 0
}

write_complete "${run_note}Every non-excluded campaign cell satisfies its execution policy, with empty pending/failed buckets; merged campaign results written to \`runs/$CAMPAIGN_ID/results.json\` for judge backfill."
```
