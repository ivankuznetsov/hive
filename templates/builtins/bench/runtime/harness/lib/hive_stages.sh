#!/usr/bin/env bash
# Runs INSIDE hive-bench-runner: drives REAL hive plan->execute->open-pr->review
# for one seeded task and captures the candidate diffs. Invoked by
# HiveBench::HiveDriver. /work is the seeded target clone — a .hive-state git
# repo with the task at 2-brainstorm, a config.yml, and NO origin remote (so the
# execute worktree branches off the task's local main = base_commit).
#
#   hive_stages.sh <slug> <base_commit>
#   HB_REVIEW=0 skips open-pr + review (plan+execute only).
#
# Markers on stdout (parsed by the driver): `HB_STAGE <name> rc=<n>`,
# `HB_NOTE <x>`, `HB_DIFF <label> lines=<n> files=<n>`, `HB_DONE`.
set -uo pipefail

SLUG="$1"
BASE="$2"
export HOME=/home/asterio
git config --global --add safe.directory '*' 2>/dev/null
mkdir -p /work/.hb/bin
HIVE_RUNTIME_BIN=/opt/hb/hive-current/bin
if [ ! -x "$HIVE_RUNTIME_BIN/hive" ] || [ -z "${HB_HIVE_VERSION:-}" ]; then
  echo "HB_ERROR hive_runtime_missing" >&2
  exit 4
fi
ACTUAL_HIVE_VERSION="$("$HIVE_RUNTIME_BIN/hive" --version 2>/dev/null)"
if [ "$ACTUAL_HIVE_VERSION" != "$HB_HIVE_VERSION" ]; then
  echo "HB_ERROR hive_runtime_version_mismatch expected=$HB_HIVE_VERSION actual=$ACTUAL_HIVE_VERSION" >&2
  exit 4
fi
export PATH="/work/.hb/bin:$HIVE_RUNTIME_BIN:$PATH"
echo "HB_NOTE hive_runtime version=$ACTUAL_HIVE_VERSION"
cd /work || exit 3

stage() { echo "HB_STAGE $1 rc=$2"; }

preflight_opencode_ce_skills() {
  local package=/opt/compound-engineering
  local config_out=/work/.hb/opencode-ce-config.json
  local skills_out=/work/.hb/opencode-ce-skills.json
  local required

  for required in ce-plan ce-work ce-code-review; do
    if [ ! -f "$package/skills/$required/SKILL.md" ]; then
      echo "HB_ERROR opencode_ce_skills missing=$required" >&2
      return 1
    fi
  done

  mkdir -p "$HOME/.agents" || return 1
  ln -sfn "$package/skills" "$HOME/.agents/skills" || return 1

  if ! timeout 90 env \
    OPENCODE_CONFIG_CONTENT='{"plugin":["/opt/compound-engineering"]}' \
    opencode debug config >"$config_out"; then
    echo "HB_ERROR opencode_ce_skills config_probe_failed" >&2
    return 1
  fi
  if ! timeout 90 env \
    OPENCODE_CONFIG_CONTENT='{"plugin":["/opt/compound-engineering"]}' \
    opencode debug skill >"$skills_out"; then
    echo "HB_ERROR opencode_ce_skills discovery_probe_failed" >&2
    return 1
  fi

  ruby -rjson -e '
    config = JSON.parse(File.read(ARGV.fetch(0)))
    skills = JSON.parse(File.read(ARGV.fetch(1)))
    paths = Array(config.dig("skills", "paths"))
    commands = config.fetch("command", {}).keys
    names = skills.filter_map { |skill| skill["name"] }
    required = %w[ce-plan ce-work ce-code-review]
    abort "missing CE skill path" unless paths.include?("/opt/compound-engineering/skills")
    abort "missing CE commands" unless (required - commands).empty?
    abort "missing CE skills" unless (required - names).empty?
    count = names.count { |name| name.start_with?("ce-") || name == "lfg" }
    abort "incomplete CE skill corpus" unless count == 33
  ' "$config_out" "$skills_out" || {
    echo "HB_ERROR opencode_ce_skills validation_failed" >&2
    return 1
  }

  echo "HB_NOTE opencode_ce_skills enabled count=33"
}

if [ "${HB_OPENCODE_CE_PREFLIGHT:-0}" = "1" ]; then
  preflight_opencode_ce_skills || exit 4
fi

install_pi_openrouter_auth() {
  local auth_dir="$HOME/.pi/agent"
  if [ -z "${OPENROUTER_API_KEY:-}" ]; then
    echo "HB_ERROR pi_openrouter_auth missing OPENROUTER_API_KEY" >&2
    return 1
  fi
  mkdir -p "$auth_dir" || return 1
  ruby -rjson -rfileutils -e '
    dir = ARGV.fetch(0)
    path = File.join(dir, "auth.json")
    tmp = File.join(dir, ".auth.json.tmp-#{Process.pid}")
    begin
      payload = { "openrouter" => { "type" => "api_key", "key" => ENV.fetch("OPENROUTER_API_KEY") } }
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(payload))
      end
      File.rename(tmp, path)
      File.chmod(0o600, path)
    ensure
      FileUtils.rm_f(tmp)
    end
  ' "$auth_dir"
}

# Pi's transport extension requests streamed tool arguments from OpenRouter.
# Hive owns the stage model flags; this wrapper only activates the extension and
# installs the container-only credential/catalog in Pi's ephemeral home.
if [ -f /opt/hb/pi-tool-stream.ts ]; then
  PI_REAL="$(command -v pi)"
  cat >/work/.hb/bin/pi <<PI
#!/usr/bin/env bash
exec "$PI_REAL" --extension /opt/hb/pi-tool-stream.ts "\$@"
PI
  chmod +x /work/.hb/bin/pi
  mkdir -p "$HOME/.pi/agent"
  if [ -f /opt/hb/pi-openrouter-models.json ]; then
    install_pi_openrouter_auth || exit 4
    ln -sfn /opt/hb/pi-openrouter-models.json "$HOME/.pi/agent/models.json"
    echo "HB_NOTE pi_openrouter_models enabled"
  else
    [ -s "$HOME/.pi/agent/auth.json" ] || \
      echo '{"bench-preflight":{"type":"api_key","key":"container-only-placeholder"}}' \
        >"$HOME/.pi/agent/auth.json"
    chmod 600 "$HOME/.pi/agent/auth.json"
  fi
  echo "HB_NOTE pi_tool_stream enabled"
fi

# BEGIN grok-auth-preflight
# Hive 0.3.6 checks only ~/.grok/auth.json before launching the agent and does
# not honor GROK_AUTH_PATH. The home is a per-cell tmpfs, so expose a symlink
# for Hive's read-only preflight while Grok keeps using the canonical shared
# path (and its adjacent refresh lock) through GROK_AUTH_PATH.
if [ -n "${GROK_AUTH_PATH:-}" ]; then
  if [ ! -f "$GROK_AUTH_PATH" ]; then
    echo "HB_ERROR grok_auth_preflight missing credential: $GROK_AUTH_PATH" >&2
    exit 4
  fi
  mkdir -p "$HOME/.grok" || {
    echo "HB_ERROR grok_auth_preflight cannot create $HOME/.grok" >&2
    exit 4
  }
  ln -sfn "$GROK_AUTH_PATH" "$HOME/.grok/auth.json" || {
    echo "HB_ERROR grok_auth_preflight cannot link $HOME/.grok/auth.json" >&2
    exit 4
  }
fi
# END grok-auth-preflight

# Native CE skills (prod parity): the driver mounts each CLI's skill tree ro at
# a neutral /opt/hb path; link it into the CLI's discovery path here, inside
# the writable tmpfs (a direct bind under the tmpfs would leave root-owned
# parent dirs that kill the CLIs — the .claude/.codex lesson).
if [ -d /opt/hb/codex-plugins-cache ]; then
  mkdir -p "$HOME/.codex/plugins"
  [ -e "$HOME/.codex/plugins/cache" ] || ln -s /opt/hb/codex-plugins-cache "$HOME/.codex/plugins/cache"
  echo "HB_NOTE codex_skills linked: $(find /opt/hb/codex-plugins-cache -mindepth 1 -maxdepth 1 -printf '%f ')"
fi
if [ -d /opt/hb/pi-ce-skills ]; then
  mkdir -p "$HOME/.pi/agent/skills"
  for s in /opt/hb/pi-ce-skills/*/; do
    n="$(basename "$s")"
    [ -e "$HOME/.pi/agent/skills/$n" ] || ln -s "${s%/}" "$HOME/.pi/agent/skills/$n"
  done
  echo "HB_NOTE pi_skills linked: $(find /opt/hb/pi-ce-skills -mindepth 1 -maxdepth 1 -printf '.' | wc -c) skills"
fi

# Capture the task worktree's diff vs base into $1: committed + uncommitted +
# untracked (agents often leave work uncommitted), minus vendored/build trees.
# Pathspecs mirror GitRestore::VENDORED_EXCLUDES — keep them in sync. The
# `.hive_probe_tmp` entry is container-only harness scratch state.
CAPTURE_EXCLUDES=(
  ':(exclude,glob).gems/**' ':(exclude).gems'
  ':(exclude,glob)**/node_modules/**'
  ':(exclude,glob)vendor/bundle/**' ':(exclude,glob)vendor/gems/**'
  ':(exclude,glob)vendor/cache/**' ':(exclude,glob).bundle/**'
  ':(exclude,glob).bundle-local/**' ':(exclude).bundle-local'
  ':(exclude).hive-bench-prompt.md' ':(exclude).hive_probe_tmp'
)

capture() {
  local out="$1" label="$2" root="${3:-/work}"
  local wt p b untracked
  wt="$(find "$root/.hive-state/stages" -name worktree.yml 2>/dev/null | head -1)"
  [ -n "$wt" ] || return 1
  p="$(ruby -ryaml -e 'puts(YAML.load_file(ARGV[0])["path"].to_s)' "$wt" 2>/dev/null)"
  b="$(ruby -ryaml -e 'puts(YAML.load_file(ARGV[0])["execute_base_head"].to_s)' "$wt" 2>/dev/null)"
  [ -z "$b" ] && b="$BASE"
  if [ -n "$p" ] && git -C "$p" rev-parse >/dev/null 2>&1; then
    # Enumerate only non-ignored, non-vendored new files before intent-to-add.
    # Passing `.` directly to git add makes any ignored build tree return 1 even
    # when an exclude pathspec keeps it out of the index.
    untracked="$(mktemp "${TMPDIR:-/tmp}/hb-untracked.XXXXXX")" || return 1
    if ! git -C "$p" ls-files --others --exclude-standard -z -- . "${CAPTURE_EXCLUDES[@]}" \
      >"$untracked"; then
      rm -f "$untracked" "$out"
      echo "HB_ERROR capture_failed label=$label phase=untracked_scan" >&2
      return 1
    fi
    if [ -s "$untracked" ] && ! git -C "$p" --literal-pathspecs add --intent-to-add \
      --pathspec-from-file="$untracked" --pathspec-file-nul >/dev/null 2>&1; then
      rm -f "$untracked" "$out"
      echo "HB_ERROR capture_failed label=$label phase=intent_to_add" >&2
      return 1
    fi
    rm -f "$untracked"
    if ! git -C "$p" diff --no-ext-diff --no-textconv "$b" -- . "${CAPTURE_EXCLUDES[@]}" \
      >"$out" 2>/dev/null; then
      rm -f "$out"
      echo "HB_ERROR capture_failed label=$label phase=diff" >&2
      return 1
    fi
    echo "HB_DIFF $label lines=$(wc -l <"$out") files=$(grep -c '^diff --git' "$out")"
    return 0
  fi

  echo "HB_ERROR capture_failed label=$label phase=worktree" >&2
  return 1
}

replace_candidate_patch() {
  local source="$1" destination="$2" tmp="${2}.tmp.$$"
  rm -f "$tmp"
  if ! cp "$source" "$tmp" || ! mv -f "$tmp" "$destination"; then
    rm -f "$tmp" "$destination"
    echo "HB_ERROR candidate_patch_copy_failed" >&2
    return 1
  fi
}

# A failed review is not allowed to replace a valid implementation with its
# partial working-tree side effects. This is the documented benchmark contract:
# score the execute patch and surface review_ok=false in telemetry.
finalize_candidate_patch() {
  local review_rc="$1" work="${2:-/work}"
  if [ -n "$review_rc" ] && [ "$review_rc" -ne 0 ]; then
    if [ ! -f "$work/candidate-execute.patch" ]; then
      rm -f "$work/candidate.patch"
      echo "HB_ERROR execute_patch_missing_after_review_failure" >&2
      return 1
    fi
    replace_candidate_patch "$work/candidate-execute.patch" "$work/candidate.patch" || return 1
    echo "HB_NOTE review_fallback=execute"
    return 0
  fi

  capture "$work/candidate.patch" final "$work" || return 1
  if [ ! -s "$work/candidate.patch" ] && [ -f "$work/candidate-execute.patch" ]; then
    replace_candidate_patch "$work/candidate-execute.patch" "$work/candidate.patch" || return 1
  fi
}

# A durable stage action can successfully promote a task yet leave the target
# markerless, with `next_action=ready_to_run`. Follow that native continuation
# once so a successful wrapper receipt cannot be mistaken for a produced plan.
# PLAN_MD is intentionally global for the caller.
ensure_plan_artifact() {
  local plan_task="$1" state_root="${2:-/work/.hive-state}" hb_root="${3:-/work/.hb}" rc
  PLAN_MD="$(find "$state_root/stages/3-plan" -name plan.md 2>/dev/null | head -1)"
  [ -n "$PLAN_MD" ] && [ -f "$PLAN_MD" ] && return 0
  if [ -z "$plan_task" ] || [ ! -d "$plan_task" ]; then
    echo "HB_ERROR plan_artifact_missing phase=task" >&2
    return 1
  fi

  hive run "$plan_task" --json >"$hb_root/plan-run.json" 2>>"$hb_root/stage.err"
  rc=$?
  stage plan-run "$rc"
  [ "$rc" -eq 0 ] || return "$rc"

  PLAN_MD="$(find "$state_root/stages/3-plan" -name plan.md 2>/dev/null | head -1)"
  if [ -z "$PLAN_MD" ] || [ ! -f "$PLAN_MD" ]; then
    echo "HB_ERROR plan_artifact_missing phase=run" >&2
    return 1
  fi
  echo "HB_NOTE plan_stage_resumed"
}

# Accept a planner's unanswered-question pause without letting Hive's runtime
# lock files leak into the state-branch bookkeeping commit. The plan document
# is the benchmark deliverable; only that document belongs in this commit.
force_plan_complete() {
  local plan_md="$1" state_root="${2:-/work/.hive-state}" plan_rel
  plan_rel="${plan_md#"$state_root"/}"
  if [ -z "$plan_md" ] || [ "$plan_rel" = "$plan_md" ] || [ ! -f "$plan_md" ]; then
    echo "HB_ERROR plan_force_failed phase=path" >&2
    return 1
  fi
  if ! sed -i 's/<!-- WAITING -->/<!-- COMPLETE -->/' "$plan_md"; then
    echo "HB_ERROR plan_force_failed phase=rewrite" >&2
    return 1
  fi
  if ! git -C "$state_root" add -- "$plan_rel"; then
    echo "HB_ERROR plan_force_failed phase=stage" >&2
    return 1
  fi
  if ! git -C "$state_root" -c user.email=bench@hive-bench -c user.name=hive-bench \
    commit -qm 'bench: force plan complete (no human Q&A)' -- "$plan_rel"; then
    echo "HB_ERROR plan_force_failed phase=commit" >&2
    return 1
  fi
  echo "HB_NOTE plan_forced_complete"
}

# A dependency-free plan must omit `depends_on`; YAML null is not a dependency
# identifier and current Hive correctly rejects it. Some model/CE combinations
# emit the explicit null despite meaning "none". Remove only that exact
# semantics-preserving form and commit only the plan artifact, just like the
# unattended WAITING-to-COMPLETE normalization above.
normalize_null_plan_dependency() {
  local plan_md="$1" state_root="${2:-/work/.hive-state}" plan_rel
  [ -f "$plan_md" ] || return 0
  grep -Eq '^depends_on:[[:space:]]*(null|~)[[:space:]]*$' "$plan_md" || return 0
  plan_rel="${plan_md#"$state_root"/}"
  if [ "$plan_rel" = "$plan_md" ]; then
    echo "HB_ERROR plan_dependency_normalize_failed phase=path" >&2
    return 1
  fi
  if ! ruby -e '
    path = ARGV.fetch(0)
    source = File.read(path)
    rewritten = source.sub(/^depends_on:[ \t]*(?:null|~)[ \t]*$\n/, "")
    abort "null dependency not found" if rewritten == source
    File.write(path, rewritten)
  ' "$plan_md"; then
    echo "HB_ERROR plan_dependency_normalize_failed phase=rewrite" >&2
    return 1
  fi
  if ! git -C "$state_root" add -- "$plan_rel" ||
     ! git -C "$state_root" -c user.email=bench@hive-bench -c user.name=hive-bench \
       commit -qm 'bench: omit null plan dependency' -- "$plan_rel"; then
    echo "HB_ERROR plan_dependency_normalize_failed phase=commit" >&2
    return 1
  fi
  echo "HB_NOTE plan_dependency_null_removed"
}

# 1. PLAN — real /ce-plan, or reuse the identity-verified plan when the host
# driver resumes an execute turn interrupted by exact model transport evidence
# or a post-cleanup dirty-worktree marker. Clear exactly the verified ordinary
# marker, or complete Hive-validated committed residue, before continuing.
PLAN_TASK=""
EXECUTE_RESIDUE_RECOVERED=0
RESUME_REVIEW="${HB_RESUME_REVIEW:-0}"
if [ "$RESUME_REVIEW" = "1" ]; then
  PLAN_TASK="/work/.hive-state/stages/6-review/$SLUG"
  if [ ! -d "$PLAN_TASK" ] || [ ! -s /work/candidate-execute.patch ]; then
    echo "HB_ERROR review_resume_preflight_failed" >&2
    exit 5
  fi
  stage plan 0
  echo "HB_NOTE plan_reused"
  echo "HB_NOTE review_resumed"
elif [ "${HB_RESUME_EXECUTE:-0}" = "1" ]; then
  PLAN_TASK="/work/.hive-state/stages/4-execute/$SLUG"
  bash /hive_resume_execute.sh "$PLAN_TASK" "${HB_RESUME_MARKER_ID:-}" \
    /work/.hb/resume-clear.json /work/.hb/stage.err
  RESUME_CLEAR_RC=$?
  stage resume-clear "$RESUME_CLEAR_RC"
  [ "$RESUME_CLEAR_RC" -eq 0 ] || exit 5
  stage plan 0
  echo "HB_NOTE plan_reused"
  echo "HB_NOTE execute_resumed"
  if [ -f /work/.hb/execute-residue-recovered ]; then
    EXECUTE_RESIDUE_RECOVERED=1
    echo "HB_NOTE execute_residue_recovered"
  fi
else
  hive plan "/work/.hive-state/stages/2-brainstorm/$SLUG" --json >/work/.hb/plan.json 2>>/work/.hb/stage.err
  PLAN_RC=$?
  stage plan "$PLAN_RC"
  if [ "$PLAN_RC" -ne 0 ]; then
    # A failed Hive stage can leave a partial plan.md alongside its durable
    # error marker. That file is not a completed planning result and must not
    # be fed to develop; the outer campaign may retry this cell from a clean
    # seed when the provider failure is transient.
    echo "HB_NOTE plan_failed"
    exit 4
  fi

  PLAN_TASK="$(find /work/.hive-state/stages/3-plan -mindepth 1 -maxdepth 1 -type d -name "$SLUG" 2>/dev/null | head -1)"
  ensure_plan_artifact "$PLAN_TASK" || exit 4

  # /ce-plan ends WAITING when it raised open questions. With no human in the loop,
  # accept the plan as-is: the plan document is the deliverable; the Q&A refinement
  # loop is out of scope for the benchmark. Flip the marker so execute can proceed.
  if [ -n "$PLAN_MD" ] && grep -q '<!-- WAITING -->' "$PLAN_MD"; then
    force_plan_complete "$PLAN_MD"
  fi
  normalize_null_plan_dependency "$PLAN_MD" || exit 4
  PLAN_TASK="$(dirname "$PLAN_MD" 2>/dev/null)"
fi

# 2. EXECUTE — real develop -> worktree off base_commit.
if [ "$RESUME_REVIEW" = "1" ] || [ "$EXECUTE_RESIDUE_RECOVERED" -eq 1 ]; then
  stage develop 0
elif [ -n "$PLAN_TASK" ] && [ "$PLAN_TASK" != "." ]; then
  hive develop "$PLAN_TASK" --json >/work/.hb/develop.json 2>>/work/.hb/stage.err
  stage develop $?
fi

# Post-execute capture: the raw first-pass diff, kept for review-lift analysis.
if [ "$RESUME_REVIEW" = "1" ]; then
  echo "HB_DIFF execute lines=$(wc -l </work/candidate-execute.patch) files=$(grep -c '^diff --git' /work/candidate-execute.patch)"
else
  if ! capture /work/candidate-execute.patch execute; then
    echo "HB_NOTE execute_patch_failed"
    exit 4
  fi
fi

# 3-4. OPEN-PR + REVIEW — the rest of the real hive cycle (HB_REVIEW=0 skips).
# The container has no GitHub: pushes land on a bench-local bare origin, and a
# minimal gh shim answers the PR calls the stages make. github_publish is
# disabled in the bench config, so review never needs the real API.
# hive moves the task folder across stage dirs as stages complete — always
# re-resolve by slug instead of assuming which stage dir it landed in.
task_dir() { find /work/.hive-state/stages -maxdepth 2 -type d -name "$SLUG" 2>/dev/null | head -1; }

REVIEW_RC=""
if [ "${HB_REVIEW:-1}" = "1" ] && [ -n "$PLAN_TASK" ] && [ "$PLAN_TASK" != "." ]; then
  git init -q --bare /work/.hb/origin.git 2>/dev/null
  git -C /work remote add origin /work/.hb/origin.git 2>/dev/null
  git -C /work push -q origin main 2>/dev/null

  cat >/work/.hb/bin/gh <<'GH'
#!/usr/bin/env bash
# bench gh shim: enough of gh for hive's open-pr/review in an offline container.
# Contract (lib/hive/gh.rb): `pr list --head <branch> --state all --json
# url,number,state,isDraft,headRefName,headRefOid` must return an ARRAY of PRs
# whose headRefOid hive may compare against the pushed branch.
branch=""; prev=""
for a in "$@"; do [ "$prev" = "--head" ] && branch="$a"; prev="$a"; done
URL="https://github.com/bench/target/pull/1"
case "$1 ${2:-}" in
  "pr create"*) echo "$URL" ;;
  "pr list"*)
    oid="$(git rev-parse "$branch" 2>/dev/null || echo "")"
    printf '[{"url":"%s","number":1,"state":"OPEN","isDraft":false,"headRefName":"%s","headRefOid":"%s"}]\n' \
      "$URL" "$branch" "$oid" ;;
  "pr view"*)   echo "{\"state\":\"OPEN\",\"number\":1,\"url\":\"$URL\",\"statusCheckRollup\":[]}" ;;
  "pr checks"*) echo "no checks reported" ;;
  "auth status"*) echo "Logged in (bench shim)" ;;
  *" list"*|"pr list") echo "[]" ;;
  *) echo "{}" ;;
esac
exit 0
GH
  chmod +x /work/.hb/bin/gh

  if [ "$RESUME_REVIEW" = "1" ]; then
    stage open-pr 0
  else
    hive open-pr "$(task_dir)" --json >/work/.hb/open_pr.json 2>>/work/.hb/stage.err
    stage open-pr $?
  fi
  hive review "$(task_dir)" --json >/work/.hb/review.json 2>>/work/.hb/stage.err
  REVIEW_RC=$?
  stage review "$REVIEW_RC"

  ST="$(find /work/.hive-state/stages -name status.md -path "*$SLUG*" 2>/dev/null | head -1)"
  for m in REVIEW_COMPLETE REVIEW_WAITING REVIEW_STALE; do
    if [ -n "$ST" ] && grep -q "$m" "$ST"; then echo "HB_NOTE review_status=$m"; break; fi
  done
fi

# Final capture: post-review only when review succeeded. A failed review falls
# back to the valid execute diff rather than scoring partial review side effects.
if ! finalize_candidate_patch "$REVIEW_RC" /work; then
  echo "HB_NOTE final_patch_failed"
  exit 4
fi
echo "HB_DONE"
