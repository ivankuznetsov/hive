#!/usr/bin/env bash
set -euo pipefail

evidence_root="$RUNNER_TEMP/terminal-evidence"
receipt_root="$evidence_root/receipts"
mkdir -p "$receipt_root"
artifacts="$evidence_root/current-artifacts.json"
receipt_errors="$evidence_root/receipt-errors.txt"
: > "$receipt_errors"
gh api "repos/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}/artifacts?per_page=100" \
  > "$artifacts"
while IFS=$'\t' read -r artifact_id artifact_name; do
  zip="$evidence_root/${artifact_name}.zip"
  if gh api -H "Accept: application/vnd.github+json" \
    "repos/${GITHUB_REPOSITORY}/actions/artifacts/${artifact_id}/zip" > "$zip" &&
      unzip -nq "$zip" -d "$receipt_root"; then
    :
  else
    printf '%s\n' "$artifact_name" >> "$receipt_errors"
  fi
done < <(
  jq -r --arg prefix \
    "hive-release-candidate-gate-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-" '
      .artifacts[] |
      select(.expired == false and (.name | startswith($prefix))) |
      [.id, .name] | @tsv
    ' "$artifacts"
)
ruby -rjson -e '
  rows = Dir.glob(File.join(ARGV.fetch(0), "*.json")).sort.filter_map do |path|
    JSON.parse(File.binread(path))
  rescue JSON::ParserError
    {"schema" => "invalid-receipt", "path" => File.basename(path)}
  end
  File.readlines(ARGV.fetch(1), chomp: true).reject(&:empty?).each do |name|
    rows << {"schema" => "invalid-receipt-artifact", "artifact_name" => name}
  end
  File.write(ARGV.fetch(2), JSON.generate("receipts" => rows))
' "$receipt_root" "$receipt_errors" "$evidence_root/receipts.json"

if test -n "$SOURCE_RUN_ID"; then
  source_dir="$evidence_root/source"
  gh run download "$SOURCE_RUN_ID" --repo "$GITHUB_REPOSITORY" \
    --name "hive-release-candidate-evidence-${SOURCE_RUN_ID}-${SOURCE_RUN_ATTEMPT}" \
    --dir "$source_dir"
  actual="$(sha256sum "$source_dir/evidence.json" | awk '{print $1}')"
  test "$actual" = "$SOURCE_EVIDENCE_SHA256"
fi
