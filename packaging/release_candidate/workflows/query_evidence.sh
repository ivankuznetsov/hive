#!/usr/bin/env bash
set -euo pipefail

evidence_root="$RUNNER_TEMP/terminal-evidence"
mkdir -p "$evidence_root"
gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/attempts/${GITHUB_RUN_ATTEMPT}/jobs?per_page=100" \
  > "$evidence_root/jobs.json"
gh api "repos/${GITHUB_REPOSITORY}/commits/${CANDIDATE_SHA}/check-runs?check_name=rake%20test%20%28Ruby%203.4%29" \
  > "$evidence_root/checks.raw.json"
cp "$evidence_root/checks.raw.json" "$evidence_root/checks.json"

mapfile -t ordinary_ids < <(
  jq -r '.check_runs[] | select(
    .name == "rake test (Ruby 3.4)" and
    .app.slug == "github-actions"
  ) | .details_url | capture("/actions/runs/(?<id>[0-9]+)").id' \
    "$evidence_root/checks.raw.json"
)
if test "${#ordinary_ids[@]}" = 1; then
  gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${ordinary_ids[0]}" \
    > "$evidence_root/ordinary-run.json"
  jq --slurpfile run "$evidence_root/ordinary-run.json" '
    .check_runs |= map(
      if .name == "rake test (Ruby 3.4)" and .app.slug == "github-actions"
      then . + {
        workflow_path:$run[0].path,
        run_id:$run[0].id,
        run_attempt:$run[0].run_attempt
      }
      else .
      end
    )
  ' "$evidence_root/checks.raw.json" > "$evidence_root/checks.json"
fi
