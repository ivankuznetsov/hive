#!/usr/bin/env bash
set -euo pipefail

# Compile wiki/log.md from append-only wiki/log.d/*.md fragments.
#
# Single source of truth for the LLM-wiki changelog format, shared verbatim by
# the llm-wiki plugin and by hive (Hive::WikiLog delegates here). Output is
# byte-identical to the prior Ruby implementation for all well-formed logs (a
# header plus exactly one generated block); a malformed log with multiple
# generated blocks is normalized (every BEGIN/END pair is excised), which the
# prior Ruby — a single non-greedy sub — did not do. Layout:
#
#   <HEADER, rstripped>
#
#   <!-- BEGIN GENERATED WIKI LOG FRAGMENTS -->
#   <fragment N>            # String#strip'd, newest-first (LC_ALL=C sort -r), \n\n-joined
#
#   <fragment N-1>
#   ...
#   <!-- END GENERATED WIKI LOG FRAGMENTS -->
#
#   <legacy ## entries that predate the generated block, if any>
#
# Usage:
#   compile-log.sh <project_root>            # rewrite <root>/wiki/log.md in place
#   compile-log.sh <project_root> --print    # emit compiled content to stdout, no write

root="${1:?usage: compile-log.sh <project_root> [--print]}"
mode="${2:-write}"
root="$(cd "$root" && pwd)"
log_dir="$root/wiki/log.d"
log_path="$root/wiki/log.md"

HEADER_RSTRIP='# Wiki Changelog

Append-only log of all wiki operations.'
BEGIN_MARKER='<!-- BEGIN GENERATED WIKI LOG FRAGMENTS -->'
END_MARKER='<!-- END GENERATED WIKI LOG FRAGMENTS -->'

# Trim leading+trailing whitespace of an entire file like Ruby String#strip.
# Pinned to LC_ALL=C so [[:space:]] is the ASCII set (space \t \n \r \v \f),
# matching Ruby across locales/awk implementations. (Ruby additionally strips a
# NUL byte; ignored here since changelog fragments are text.) Emits the stripped
# body with no trailing newline.
strip_file() {
  LC_ALL=C awk '{ buf = (NR == 1 ? $0 : buf "\n" $0) }
       END {
         gsub(/^[[:space:]]+/, "", buf)
         gsub(/[[:space:]]+$/, "", buf)
         printf "%s", buf
       }' "$1"
}

# fragments, newest-first; drop empties (matches read_fragments filter_map)
body=""
first=1
if compgen -G "$log_dir/*.md" >/dev/null 2>&1; then
  while IFS= read -r frag; do
    stripped="$(strip_file "$frag")"
    [ -n "$stripped" ] || continue
    if [ "$first" -eq 1 ]; then
      body="$stripped"
      first=0
    else
      body="$body"$'\n\n'"$stripped"
    fi
  done < <(printf '%s\n' "$log_dir"/*.md | LC_ALL=C sort -r)
fi

if [ -z "$body" ]; then
  generated="$BEGIN_MARKER"$'\n'"$END_MARKER"
else
  generated="$BEGIN_MARKER"$'\n'"$body"$'\n'"$END_MARKER"
fi

# legacy_body: hand-written "## " entries that predate the generated block —
# which can sit BOTH before the BEGIN marker and after the END marker. Matches
# the Ruby legacy_body for well-formed logs: excise the generated block
# (BEGIN..END inclusive, plus the blank lines immediately after END, matching the
# Ruby `END\n*`), then keep everything from the first "## " heading onward,
# String#strip'd. The blank line that naturally precedes BEGIN stays, so pre-block
# and post-block entries join with exactly one blank line. (Unlike the Ruby single
# non-greedy sub, this excises EVERY BEGIN/END pair — relevant only for a
# malformed multi-block log, which it normalizes to one block.)
legacy=""
if [ -f "$log_path" ]; then
  legacy="$(
    LC_ALL=C awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
      in_block { if (index($0, e)) { in_block = 0; after_end = 1 } ; next }
      index($0, b) { in_block = 1; next }
      after_end && /^[[:space:]]*$/ { next }
      { after_end = 0; print }
    ' "$log_path" \
    | awk 'f || /^## / { f = 1; print }' \
    | LC_ALL=C awk '{ buf = (NR == 1 ? $0 : buf "\n" $0) }
           END { gsub(/^[[:space:]]+/,"",buf); gsub(/[[:space:]]+$/,"",buf); printf "%s", buf }'
  )"
fi

out="$HEADER_RSTRIP"$'\n\n'"$generated"
[ -n "$legacy" ] && out="$out"$'\n\n'"$legacy"

if [ "$mode" = "--print" ]; then
  printf '%s\n' "$out"
else
  mkdir -p "$(dirname "$log_path")"
  printf '%s\n' "$out" > "$log_path"
fi
