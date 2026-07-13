# Bench Generate Stage

Run this stage from the task folder. It refuses to spend tokens until
`campaign.yml` exists, is tracked, is clean, and validates against the v3
campaign contract. On success it merges every per-cell result into
`runs/<campaign_id>/results.json`, the file the judge and publish stages
consume.

Execute the `<!-- bench-stage-script -->` bash block below verbatim with
`bash` (extract it to a file and run it, or pipe it to `bash`). Do not
reimplement its steps, improvise around failing commands, or hand-write a
`<!-- WAITING -->`/`<!-- COMPLETE -->` marker yourself — every guard in this
stage lives in the script, and the script ends every path with exactly one
marker.

<!-- bench-stage-script -->
```bash
set -euo pipefail

STATE_FILE="generate.md"

# Scratch outputs are folded into the state file below; never leave them behind
# to be swept into hive-state commits (.generate-commands carries absolute
# source paths).
trap 'rm -f .generate-validate.out .generate-validate.err .generate-campaign.out .generate-campaign.err .generate-commands .generate-commands.err .generate-cmd.err .generate-run.err .generate-outcome.out .generate-outcome.err .generate-merge.out .generate-merge.err' EXIT

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

if [ ! -f "$REPO_ROOT/harness/hive_run.rb" ]; then
  write_waiting "ERROR: ../../../.. did not resolve to the hive-bench repo root; missing harness/hive_run.rb at $REPO_ROOT."
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
  data = YAML.safe_load_file("campaign.yml")
  abort("campaign.yml must be a YAML mapping") unless data.is_a?(Hash)
  required = %w[campaign_id source corpus_version tasks candidates effort_pins seeds judges budgets timeouts exclusions aggregation]
  missing = required.reject { |key| data.key?(key) }
  abort("campaign.yml missing required key(s): #{missing.join(", ")}") unless missing.empty?
  id = data["campaign_id"].to_s
  # campaign_id becomes the runs/<campaign_id> path segment (and publish merges
  # in place there): a strict slug keeps it from escaping runs/ or colliding
  # with published campaign dirs.
  abort("campaign_id must be a slug matching /\\A[a-z0-9][a-z0-9-]{0,63}\\z/; got #{id.inspect}") unless id.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
  abort("campaign_id v3-example is the unedited example id; pick a real campaign id") if id == "v3-example"
  # source/corpus_version feed three-line `read` extractions here and in the
  # judge/publish stages: a multi-line value would silently misalign them.
  source = data["source"]
  abort("source must be a non-empty single-line string; got #{source.inspect}") unless source.is_a?(String) && !source.include?("\n") && !source.strip.empty?
  cv = data["corpus_version"]
  abort("corpus_version must be a single-line scalar; got #{cv.inspect}") unless (cv.is_a?(String) || cv.is_a?(Integer)) && !cv.to_s.include?("\n")
  abort("tasks must be a non-empty array") unless data["tasks"].is_a?(Array) && !data["tasks"].empty?
  abort("candidates must be a non-empty array") unless data["candidates"].is_a?(Array) && !data["candidates"].empty?
  abort("seeds must be a positive integer") unless data["seeds"].is_a?(Integer) && data["seeds"].positive?
  judges = data["judges"]
  abort("judges must be a mapping") unless judges.is_a?(Hash)
  unknown_judges = judges.keys.map(&:to_s) - %w[claude codex openrouter]
  abort("unknown judge backend(s): #{unknown_judges.join(", ")}") unless unknown_judges.empty?
  enabled_judges = judges.reject { |_backend, config| config.nil? || config == false }
  abort("at least two judge backends must be enabled") if enabled_judges.size < 2
  enabled_judges.each do |backend, config|
    abort("judges.#{backend} must be a mapping or null") unless config.is_a?(Hash)
    model = config["model"]
    abort("judges.#{backend}.model must be a non-empty single-line string") unless model.is_a?(String) && !model.include?("\n") && !model.strip.empty?
  end
  judge_names = enabled_judges.map do |backend, config|
    backend.to_s == "claude" ? config.fetch("model").sub(/\Aclaude-/, "") : config.fetch("model").split("/").last
  end
  abort("enabled judges must produce unique result keys; got #{judge_names.inspect}") unless judge_names.uniq.size == judge_names.size
  if enabled_judges.key?("codex")
    effort = enabled_judges.dig("codex", "reasoning_effort")
    abort("judges.codex.reasoning_effort must be a non-empty single-line string") unless effort.is_a?(String) && !effort.include?("\n") && !effort.strip.empty?
  end
  abort("exclusions must be an array") unless data["exclusions"].is_a?(Array)
  bad_exclusions = data["exclusions"].reject { |item| item.is_a?(Hash) && item.key?("task") && item.key?("candidate") }
  abort("every exclusions entry must be a {task:, candidate:} map; bad: #{bad_exclusions.inspect}") unless bad_exclusions.empty?
  # A fully-excluded matrix would produce zero commands, pass the outcome check
  # vacuously, and wedge on the unmatched per-cell merge glob.
  excluded = data["exclusions"].map { |item| [item["task"].to_s, item["candidate"].to_s] }
  matrix = data["tasks"].flat_map { |t| data["candidates"].map { |c| [t.to_s, c.to_s] } } - excluded
  abort("campaign matrix is empty: every tasks x candidates cell is excluded") if matrix.empty?
  abort("timeouts must be a mapping") unless data["timeouts"].is_a?(Hash)
  hive_timeout = data["timeouts"]["hive_seconds"]
  abort("timeouts.hive_seconds must be a positive integer when set") unless hive_timeout.nil? || (hive_timeout.is_a?(Integer) && hive_timeout.positive?)
  require File.join(repo, "harness/profiles/candidates")
  known = HiveBench::Candidates.all.map(&:id)
  unknown = data["candidates"].map(&:to_s) - known
  abort("unknown candidate id(s): #{unknown.join(", ")}") unless unknown.empty?
  missing_tasks = data["tasks"].map(&:to_s).reject { |slug| File.file?(File.join(repo, "corpus", slug, "manifest.yml")) }
  abort("unknown corpus task(s): #{missing_tasks.join(", ")}") unless missing_tasks.empty?
' "$REPO_ROOT" >.generate-validate.out 2>.generate-validate.err || {
  write_waiting "$(cat .generate-validate.err .generate-validate.out)"
  exit 0
}

ruby -ryaml -e '
  repo = ARGV.fetch(0)
  data = YAML.safe_load_file("campaign.yml")
  puts data.fetch("campaign_id")
  puts data.fetch("corpus_version")
  require File.join(repo, "harness/profiles/candidates")
  needs_openrouter = data.dig("judges", "openrouter").is_a?(Hash) ||
                      data.fetch("candidates").any? { |id| HiveBench::Candidates.by_id(id.to_s)&.pi_models }
  puts needs_openrouter
' "$REPO_ROOT" >.generate-campaign.out 2>.generate-campaign.err || {
  write_waiting "$(cat .generate-campaign.err .generate-campaign.out)"
  exit 0
}
{ read -r CAMPAIGN_ID; read -r CORPUS_VERSION; read -r NEEDS_OPENROUTER; } <.generate-campaign.out

ruby -ryaml -rshellwords -rjson -e '
  repo = ARGV.fetch(0)
  require File.join(repo, "harness/profiles/candidates")
  data = YAML.safe_load_file("campaign.yml")
  terminal = %w[generated empty_diff].freeze
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
    !Dir.glob(File.join(repo, out_dir, "*", "*", "target", "candidate.patch")).empty?
  end
  hive_timeout = data.fetch("timeouts", {})["hive_seconds"]
  data.fetch("tasks").each do |task|
    data.fetch("candidates").each do |candidate|
      next if exclusions.include?([task.to_s, candidate.to_s])
      # One out dir per cell: hive_run.rb OVERWRITES results.json per
      # invocation, so a shared campaign dir would keep only the last cell.
      out = File.join("runs", data.fetch("campaign_id").to_s, "#{candidate}--#{task}")
      next if bought.call(out) # a bought cell is never re-bought
      args = [
        "ruby", "harness/hive_run.rb",
        "--source", data.fetch("source").to_s,
        "--candidate", candidate.to_s,
        "--task", task.to_s,
        "--out", out,
        "--seeds", data.fetch("seeds").to_s,
        "--corpus-version", data.fetch("corpus_version").to_s
      ]
      judges = data.fetch("judges")
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
        args += ["--openrouter-judge", "--openrouter-judge-model", openrouter.fetch("model").to_s]
      else
        args << "--no-openrouter-judge"
      end
      env = ["env"]
      # Timeout comes from the pre-registered contract (timeouts.hive_seconds);
      # when unset, harness defaults apply, as campaign.yml.example documents.
      env << "HB_HIVE_TIMEOUT=#{hive_timeout}" if hive_timeout
      profile = HiveBench::Candidates.by_id(candidate.to_s)
      env << "HB_RUNNER_IMAGE=hive-bench-runner:grok" if profile && profile.grok_model
      puts Shellwords.join(env + args)
    end
  end
' "$REPO_ROOT" >.generate-commands 2>.generate-commands.err || {
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
  write_waiting "OPENROUTER_API_KEY is required by an enabled OpenRouter judge or pi-backed candidate."
  exit 0
fi

generate_status=0
: >.generate-run.err
while IFS= read -r command; do
  set +e
  # </dev/null: a stdin-reading descendant must not swallow queued command lines.
  # bash -c, not -lc: the stage exports everything the harness needs, and a
  # login profile would feed unattributable noise/failures into per-cell status.
  # stderr is captured per command so a pre-spend abort (e.g. a missing judge
  # key) can be surfaced next to the "missing" cell it caused.
  (cd "$REPO_ROOT" && bash -c "$command" </dev/null) 2>.generate-cmd.err
  status=$?
  set -e
  cat .generate-cmd.err >&2
  { printf -- '--- exit %s: %s\n' "$status" "$command"; tail -n 5 .generate-cmd.err; } >>.generate-run.err
  if [ "$status" -ne 0 ]; then
    generate_status="$status"
  fi
done <.generate-commands

run_note=""
if [ "$generate_status" -ne 0 ]; then
  run_note="One or more generation commands exited nonzero; per-cell results below are authoritative. "
fi

ruby -ryaml -rjson -e '
  repo = ARGV.fetch(0)
  data = YAML.safe_load_file("campaign.yml")
  terminal = %w[generated empty_diff].freeze
  exclusions = data.fetch("exclusions", []).map { |item| [item.fetch("task").to_s, item.fetch("candidate").to_s] }
  bad = []
  data.fetch("tasks").each do |task|
    data.fetch("candidates").each do |candidate|
      next if exclusions.include?([task.to_s, candidate.to_s])
      dir = File.join(repo, "runs", data.fetch("campaign_id").to_s, "#{candidate}--#{task}")
      begin
        result = JSON.parse(File.read(File.join(dir, "results.json")))
      rescue Errno::ENOENT
        bad << "#{candidate}/#{task}: missing"
        next
      rescue JSON::ParserError => e
        bad << "#{candidate}/#{task}: unreadable results.json (#{e.message[0, 80]})"
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
        next
      end
      unless Dir.glob(File.join(dir, "*", "*", "target", "candidate.patch")).empty?
        # Applies to every bucket a walled cell can land in (pending, failed,
        # or a non-terminal cells[] record): the diff is paid for either way.
        status = "judges_pending (was: #{status}) — diff already captured; do NOT regenerate. Backfill judges with harness/rejudge.rb against the campaign-root runs/#{data.fetch("campaign_id")}/results.json only — never point rejudge --out at this cell'"'"'s results.json (that erases pending[] and re-arms regeneration)"
      end
      reasons = (pending + failed).filter_map { |entry| entry["reason"] }
      bad << "#{candidate}/#{task}: #{status}#{reasons.empty? ? "" : " — #{reasons.join("; ")}"}"
    end
  end
  unless bad.empty?
    puts "unfinished=#{bad.size}"
    bad.each { |line| puts "UNFINISHED #{line}" }
    exit 2
  end
' "$REPO_ROOT" >.generate-outcome.out 2>.generate-outcome.err || {
  err_tail=""
  if [ -s .generate-run.err ]; then
    err_tail="$(printf '\n\nGeneration command stderr tails:\n%s' "$(tail -n 40 .generate-run.err)")"
  fi
  write_waiting "${run_note}$(cat .generate-outcome.err .generate-outcome.out)${err_tail}"
  exit 0
}

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
(cd "$REPO_ROOT" && ruby harness/merge_results.rb --out "runs/$CAMPAIGN_ID/results.json.next" --corpus-version "$CORPUS_VERSION" "${merge_inputs[@]}" runs/"$CAMPAIGN_ID"/*--*/results.json \
  && mv "runs/$CAMPAIGN_ID/results.json.next" "runs/$CAMPAIGN_ID/results.json") \
  >.generate-merge.out 2>.generate-merge.err || {
  rm -f "$REPO_ROOT/runs/$CAMPAIGN_ID/results.json.next"
  write_waiting "${run_note}Per-cell merge failed: $(cat .generate-merge.err .generate-merge.out)"
  exit 0
}

write_complete "${run_note}Every non-excluded campaign cell has a per-cell \`run_status\` of \`generated\` or \`empty_diff\` with empty pending/failed buckets; merged campaign results written to \`runs/$CAMPAIGN_ID/results.json\`."
```
