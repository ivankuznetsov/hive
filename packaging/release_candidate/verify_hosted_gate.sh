#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: verify_hosted_gate.sh GATE_NAME RECEIPT_SLUG" >&2
  exit 64
fi

gate_name="$1"
receipt_slug="$2"
receipt_root="${RUNNER_TEMP}/gate-receipts"
mkdir -p "$receipt_root"

case "$receipt_slug" in
  catalog)
    trusted_paths=(
      packaging/release_candidate
      test/e2e/lib
      test/e2e/coverage.yml
      schemas/hive-e2e-coverage.v1.json
      schemas/hive-e2e-selection.v1.json
    )
    ;;
  release-e2e)
    trusted_paths=(bin/hive-e2e test/e2e)
    ;;
  package)
    trusted_paths=(packaging/release_candidate packaging/managed_web_archive.rb)
    ;;
  managed-web)
    trusted_paths=(
      packaging/live_agent_skills/install_candidate_gem.sh
      packaging/verify-managed-web-setup.sh
    )
    ;;
  native-*)
    trusted_paths=(packaging/live_agent_skills/install_candidate_gem.sh)
    ;;
  upgrade-*)
    trusted_paths=(packaging/release_candidate)
    ;;
  freshness|candidate-version)
    trusted_paths=(packaging/release_candidate/baseline_catalog.rb)
    ;;
  *)
    echo "verify-hosted-gate: unknown trusted harness set ${receipt_slug}" >&2
    exit 64
    ;;
esac

for path in "${trusted_paths[@]}"; do
  if ! git diff --no-index --quiet --no-ext-diff -- \
    ".trusted-control/${path}" "$path"; then
    echo "verify-hosted-gate: candidate-controlled harness drift at ${path}" >&2
    exit 1
  fi
done

producer_run="$receipt_root/${receipt_slug}-producer-run.json"
artifact="$receipt_root/${receipt_slug}-artifact.json"
receipt="$receipt_root/${receipt_slug}.json"

gh api \
  "repos/${GITHUB_REPOSITORY}/actions/runs/${ARTIFACT_PRODUCER_RUN_ID}" \
  > "$producer_run"
gh api \
  "repos/${GITHUB_REPOSITORY}/actions/artifacts/${ARTIFACT_ID}" \
  > "$artifact"

GATE_NAME="$gate_name" \
PRODUCER_RUN_ID="$ARTIFACT_PRODUCER_RUN_ID" \
PRODUCER_RUN_ATTEMPT="$ARTIFACT_PRODUCER_RUN_ATTEMPT" \
ruby .trusted-control/packaging/release_candidate/hosted_gate.rb \
  "$producer_run" "$artifact" "$RUNNER_TEMP/candidate" "$receipt"
