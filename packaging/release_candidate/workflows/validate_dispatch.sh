#!/usr/bin/env bash
set -euo pipefail

workflow_sha="${WORKFLOW_SHA:?}"
trusted_control="${TRUSTED_CONTROL:?}"

computed_action_lock="$(
  WORKFLOW_SHA="$workflow_sha" ruby -rdigest -rjson -e '
    paths = %w[.github/workflows/release-candidate.yml .github/workflows/release.yml]
    rows = paths.sort.flat_map do |path|
      source = IO.popen(
        ["git", "show", "#{ENV.fetch("WORKFLOW_SHA")}:#{path}"],
        err: File::NULL, &:read
      )
      abort("cannot read trusted workflow #{path}") unless $?.success?
      source.lines.filter_map do |line|
        match = line.match(/^\s*(?:-\s*)?uses:\s+([^@\s]+)(?:@([^#\s]+))?/)
        next unless match
        next if match[1].start_with?("./")
        abort("mutable Action ref: #{match[1]}@#{match[2]}") unless
          match[2]&.match?(/\A[0-9a-f]{40}\z/)
        {"workflow" => path, "action" => match[1], "revision" => match[2]}
      end
    end
    print Digest::SHA256.hexdigest(JSON.generate(rows))
  '
)"
test "$computed_action_lock" = "$ACTION_LOCK_SHA256"

retry=false
selected_gates="$(
  ruby -I"$trusted_control" \
    -r"$trusted_control/packaging/release_candidate/aggregate" -rjson -e \
    'print JSON.generate(HiveReleaseCandidate::Aggregate::REQUIRED_JOBS.sort)'
)"
source_evidence_sha256=""

if [[ -n "$SOURCE_RUN_ID$SOURCE_RUN_ATTEMPT$SOURCE_ARTIFACT_ID$SOURCE_ARTIFACT_DIGEST$SOURCE_ARTIFACT_RUN_ID$SOURCE_ARTIFACT_RUN_ATTEMPT$SOURCE_ARTIFACT_NAME$SELECTOR" ]]; then
  [[ "$SOURCE_RUN_ID" =~ ^[1-9][0-9]*$ ]]
  [[ "$SOURCE_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]
  [[ "$SOURCE_ARTIFACT_ID" =~ ^[1-9][0-9]*$ ]]
  [[ "$SOURCE_ARTIFACT_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]]
  [[ "$SOURCE_ARTIFACT_RUN_ID" =~ ^[1-9][0-9]*$ ]]
  [[ "$SOURCE_ARTIFACT_RUN_ATTEMPT" =~ ^[1-9][0-9]*$ ]]
  test "$SOURCE_ARTIFACT_NAME" = \
    "hive-release-candidate-${SOURCE_ARTIFACT_RUN_ID}-${SOURCE_ARTIFACT_RUN_ATTEMPT}"
  ruby -rjson -e '
    value = JSON.parse(ENV.fetch("SELECTOR"))
    abort "invalid selector" unless %w[failed missing named].include?(value["mode"])
    abort "named selector needs gates" if value["mode"] == "named" && Array(value["gates"]).empty?
  '
  source_run="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${SOURCE_RUN_ID}")"
  test "$(jq -r .id <<<"$source_run")" = "$SOURCE_RUN_ID"
  test "$(jq -r .run_attempt <<<"$source_run")" = "$SOURCE_RUN_ATTEMPT"
  test "$(jq -r .head_sha <<<"$source_run")" = "$workflow_sha"
  test "$(jq -r .path <<<"$source_run")" = ".github/workflows/release-candidate.yml"
  test "$(jq -r .event <<<"$source_run")" = workflow_dispatch
  test "$(jq -r .status <<<"$source_run")" = completed

  source_artifact="$(gh api "repos/${GITHUB_REPOSITORY}/actions/artifacts/${SOURCE_ARTIFACT_ID}")"
  test "$(jq -r .id <<<"$source_artifact")" = "$SOURCE_ARTIFACT_ID"
  test "$(jq -r .digest <<<"$source_artifact")" = "$SOURCE_ARTIFACT_DIGEST"
  test "$(jq -r .expired <<<"$source_artifact")" = false
  test "$(jq -r .name <<<"$source_artifact")" = "$SOURCE_ARTIFACT_NAME"
  test "$(jq -r .workflow_run.id <<<"$source_artifact")" = "$SOURCE_ARTIFACT_RUN_ID"
  test "$(jq -r .workflow_run.head_sha <<<"$source_artifact")" = "$workflow_sha"

  source_artifacts="$(gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${SOURCE_RUN_ID}/artifacts?per_page=100")"
  evidence_name="hive-release-candidate-evidence-${SOURCE_RUN_ID}-${SOURCE_RUN_ATTEMPT}"
  test "$(jq --arg name "$evidence_name" \
    '[.artifacts[] | select(.name == $name and .expired == false)] | length' \
    <<<"$source_artifacts")" = 1
  source_dir="$RUNNER_TEMP/source-evidence"
  gh run download "$SOURCE_RUN_ID" --repo "$GITHUB_REPOSITORY" \
    --name "$evidence_name" --dir "$source_dir"
  source_evidence="$source_dir/evidence.json"
  test "$(jq -r .candidate_sha "$source_evidence")" = "$CANDIDATE_SHA"
  test "$(jq -r .repository "$source_evidence")" = "$GITHUB_REPOSITORY"
  test "$(jq -r .trust_scope "$source_evidence")" = trusted_remote
  test "$(jq -r .workflow_sha "$source_evidence")" = "$workflow_sha"
  test "$(jq -r .run_id "$source_evidence")" = "$SOURCE_RUN_ID"
  test "$(jq -r .run_attempt "$source_evidence")" = "$SOURCE_RUN_ATTEMPT"
  test "$(jq -r .action_lock_sha256 "$source_evidence")" = "$ACTION_LOCK_SHA256"
  test "$(jq -r .artifact.id "$source_evidence")" = "$SOURCE_ARTIFACT_ID"
  test "$(jq -r .artifact.digest "$source_evidence")" = "$SOURCE_ARTIFACT_DIGEST"
  test "$(jq -r .artifact.name "$source_evidence")" = "$SOURCE_ARTIFACT_NAME"
  test "$(jq -r .artifact.producer_run_id "$source_evidence")" = "$SOURCE_ARTIFACT_RUN_ID"
  test "$(jq -r .artifact.producer_run_attempt "$source_evidence")" = "$SOURCE_ARTIFACT_RUN_ATTEMPT"
  source_request="$(jq -r .request_id "$source_evidence")"
  [[ "$source_request" =~ ^req-[a-z0-9]{6,48}$ ]]
  test "$(jq -r .display_title <<<"$source_run")" = \
    "hive-release-candidate:${source_request}:${CANDIDATE_SHA}"
  selected_gates="$(
    ruby -I"$trusted_control" \
      -r"$trusted_control/packaging/release_candidate/aggregate" -rjson -e '
      source = JSON.parse(File.binread(ARGV.fetch(0)))
      selector = JSON.parse(ENV.fetch("SELECTOR"))
      names = HiveReleaseCandidate::RetrySelection.new(
        required_names: HiveReleaseCandidate::Aggregate::REQUIRED_JOBS
      ).call(source: source, selector: selector)
      print JSON.generate(names)
    ' "$source_evidence"
  )"
  source_evidence_sha256="$(sha256sum "$source_evidence" | awk '{print $1}')"
  source_checks="$(gh api "repos/${GITHUB_REPOSITORY}/commits/${CANDIDATE_SHA}/check-runs?check_name=hive-release-candidate&filter=all&per_page=100")"
  test "$(jq --arg run "$SOURCE_RUN_ID" --arg attempt "$SOURCE_RUN_ATTEMPT" \
    --arg digest "$source_evidence_sha256" --arg candidate "$CANDIDATE_SHA" '
      [.check_runs[] | select(
        .name == "hive-release-candidate" and
        .app.slug == "github-actions" and
        .head_sha == $candidate and
        .status == "completed" and
        (.conclusion == "success" or .conclusion == "failure") and
        .external_id == ("hive-release-candidate:v1:" + $run + ":" + $attempt + ":" + $digest)
      )] | length
    ' <<<"$source_checks")" = 1
  retry=true
fi

echo "workflow_sha=$workflow_sha" >> "$GITHUB_OUTPUT"
echo "action_lock_sha256=$computed_action_lock" >> "$GITHUB_OUTPUT"
echo "retry=$retry" >> "$GITHUB_OUTPUT"
echo "selected_gates=$selected_gates" >> "$GITHUB_OUTPUT"
echo "source_evidence_sha256=$source_evidence_sha256" >> "$GITHUB_OUTPUT"
