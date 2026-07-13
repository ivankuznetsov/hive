# Bench Publish Stage

Run this stage from the task folder after judging. It only uses existing
harness publishing primitives: merge results and write a human-readable
leaderboard summary into this state file (the merged results themselves stay
at `runs/<campaign_id>/results.json`).

Execute the `<!-- bench-stage-script -->` bash block below verbatim with
`bash` (extract it to a file and run it, or pipe it to `bash`). Do not
reimplement its steps, improvise around failing commands, or hand-write a
`<!-- WAITING -->`/`<!-- COMPLETE -->` marker yourself — every guard in this
stage lives in the script, and the script ends every path with exactly one
marker.

<!-- bench-stage-script -->
```bash
set -euo pipefail

STATE_FILE="publish.md"

# Scratch outputs are folded into the state file below; never leave them behind
# to be swept into hive-state commits.
trap 'rm -f .publish-campaign.out .publish-campaign.err .publish-merge.out .publish-merge.err .publish-summary.out .publish-summary.err' EXIT

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
    printf 'The leaderboard summary above is appended to this state file; the merged results stay at `%s`.\n\n' "$RESULTS"
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
  write_waiting "Missing campaign.yml. Restore the committed campaign pre-registration before publishing."
  exit 0
fi

# One guarded extraction: a malformed campaign.yml must park WAITING, not kill
# the stage marker-less under `set -e`. Type-guard the two-line `read`
# extraction below: a multi-line corpus_version would be silently truncated
# into the merged artifact.
ruby -ryaml -e '
  data = YAML.safe_load_file("campaign.yml")
  id = data.fetch("campaign_id").to_s
  abort("campaign_id must be a slug matching /\\A[a-z0-9][a-z0-9-]{0,63}\\z/; got #{id.inspect}") unless id.match?(/\A[a-z0-9][a-z0-9-]{0,63}\z/)
  abort("campaign_id v3-example is the unedited example id; pick a real campaign id") if id == "v3-example"
  cv = data.fetch("corpus_version")
  abort("corpus_version must be a single-line scalar; got #{cv.inspect}") unless (cv.is_a?(String) || cv.is_a?(Integer)) && !cv.to_s.include?("\n")
  puts id
  puts cv
' >.publish-campaign.out 2>.publish-campaign.err || {
  write_waiting "$(cat .publish-campaign.err .publish-campaign.out)"
  exit 0
}
{ read -r CAMPAIGN_ID; read -r CORPUS_VERSION; } <.publish-campaign.out
RESULTS="runs/$CAMPAIGN_ID/results.json"

if [ ! -f "$REPO_ROOT/$RESULTS" ]; then
  write_waiting "Missing $RESULTS. Re-run generate/judge before publish."
  exit 0
fi

# --out .next + mv: judge backfills exist ONLY in this campaign-root file, so
# an in-place rewrite of the sole copy could lose paid judge work if it
# crashed mid-write.
(cd "$REPO_ROOT" && ruby harness/merge_results.rb --out "$RESULTS.next" --corpus-version "$CORPUS_VERSION" "$RESULTS" \
  && mv "$RESULTS.next" "$RESULTS") \
  >.publish-merge.out 2>.publish-merge.err || {
  rm -f "$REPO_ROOT/$RESULTS.next"
  write_waiting "$(cat .publish-merge.err .publish-merge.out)"
  exit 0
}

# Render to a scratch file first: a JSON/dig failure mid-render must park
# WAITING, never strand a half-written table in the state file with no marker.
ruby -rjson -e '
  data = JSON.parse(File.read(ARGV.fetch(0)))
  agents = data.fetch("agents", {})
  abort("merged results contain no agents/cells; nothing to publish") if agents.empty?
  puts "## Leaderboard Summary"
  puts
  puts "| Agent | Cells | Cross-family mean | Judged cells | Gate pass rate | Fresh | Reused | Cost USD |"
  puts "|---|---:|---|---:|---:|---:|---:|---:|"
  def fmt(value)
    value.nil? ? "n/a" : value
  end
  def mean_map(values)
    return "n/a" unless values.is_a?(Hash) && !values.empty?
    values.map { |judge, mean| "#{judge}=#{fmt(mean)}" }.join("<br>")
  end
  agents.keys.sort.each do |agent|
    row = agents.fetch(agent)
    cells = row["cells"]
    cross_mean = mean_map(row.dig("judged", "mean_quality_cross_family"))
    judged = row.dig("judged", "scored_cells")
    pass_rate = row.dig("gated", "pass_rate")
    fresh = row.dig("provenance", "fresh")
    reused = row.dig("provenance", "reused")
    cost = row.dig("efficiency", "total_cost_usd")
    puts "| #{agent} | #{fmt(cells)} | #{cross_mean} | #{fmt(judged)} | #{fmt(pass_rate)} | #{fmt(fresh)} | #{fmt(reused)} | #{fmt(cost)} |"
  end
  puts
  puts "Merged results: `#{ARGV.fetch(0)}`"
  puts
  puts "Manual site step: no assemble/gen-site-data script exists in this repo yet; publish stops at merged results plus this summary."
' "$REPO_ROOT/$RESULTS" >.publish-summary.out 2>.publish-summary.err || {
  write_waiting "Leaderboard render failed: $(cat .publish-summary.err .publish-summary.out)"
  exit 0
}

# Guarded like every other state-file I/O boundary: a failed append must not
# die marker-less under `set -e` between the render guard and write_complete.
{ printf '\n'; cat .publish-summary.out; } >>"$STATE_FILE" || {
  write_waiting "Failed to append the leaderboard summary to $STATE_FILE."
  exit 0
}
write_complete
```
