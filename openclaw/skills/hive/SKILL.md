---
name: hive
description: >-
  Run Hive's folder-based coding-agent pipeline from OpenClaw: guided CLI setup,
  project init, task creation, plan/develop/review workflows, status, daemon,
  and guarded admin commands.
version: 0.1.2
user-invocable: true
metadata:
  openclaw:
    homepage: https://github.com/ivankuznetsov/hive
    always: true
    install:
      - id: homebrew
        kind: brew
        formula: ivankuznetsov/hive/hive
        bins: [hive]
        label: Install Hive CLI with Homebrew
        os: [darwin]
---

# Hive CLI

Hive turns a repository into a folder-based coding-agent pipeline: ideas become tasks, tasks move through brainstorm, plan, develop, review, artifacts, and finalize stages, and the daemon keeps enrolled projects moving in the background.

Use this skill when the user wants to install Hive from OpenClaw, initialize the current project, create a task, inspect status, move a task through plan/develop/review, run diagnostics, start the Hivebox web UI, compile wiki changelog fragments, or administer Hive's daemon, bot, markers, metrics, and task registry.

## Install From ClawHub

Users install the OpenClaw skill with:

```bash
openclaw skills install hive-cli
```

That listing installs the `/hive` slash command. First run should normally be:

```text
/hive setup
```

## Common Paths

- `/hive setup` installs or verifies the Hive CLI, then delegates local provisioning to `hive setup`.
- `/hive status --json` shows the task board and next actions.
- `/hive new . "build this feature"` creates a new Hive task in the current project.
- `/hive plan <task-slug>`, `/hive develop <task-slug>`, and `/hive review <task-slug>` advance a task through the main coding workflow.
- `/hive web` starts the Hivebox browser surface when a user wants the local web UI.
- `/hive wiki compile-log --check` verifies that `wiki/log.md` matches the fragments in `wiki/log.d/`.
- `/hive doctor` checks local runtime and skill configuration.

## Custom Workflows

Beyond the default coding pipeline, Hive can run project-authored custom workflows: multi-stage agent work with stages, agents, and checkpoints for non-coding domains. Teams can use these for writing, feedback triage, research, content pipelines, and other repeatable work that benefits from the same folder-based handoff model.

These `/hive` commands map to the underlying `hive ...` CLI; the scaffold command is shown in bare CLI form:

- `/hive init . --workflow <id>` chooses the workflow for the whole project at initialization time, so tasks created there use that default.
- `/hive new . --workflow <id> "draft launch notes"` overrides the workflow for one task when creating it.
- `hive workflow new <id> [--template <name>]` is the existing scaffold command for creating a project-local workflow descriptor under `<hive_state_path>/workflows/`.

Agent and council stages may declare `budget_usd` and `timeout_sec` defaults.
Explicit project stage config overrides them. These are per-spawn limits: a
council can spend the limit once per reviewer, retry, round, and revise spawn.
Budgets require a selected CLI with a native budget flag (Hive logs a warning
when unavailable); timeouts also bound council command reviewers and revisers.

## CLI Detection

Before running a Hive workflow, check whether the Hive CLI is installed:

```bash
if hive --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hive
elif hv --version 2>/dev/null | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  hive_cmd=hv
else
  hive_cmd=
fi
```

If `hive_cmd` is empty, start guided setup instead of failing. Restate that setup will install the Hive CLI, verify it, install or enable the per-user daemon service, and optionally run `hive init` for the current project. Get explicit user confirmation before running installers.

## Guided Setup

Use the host platform to choose one install path:

- macOS arm64: `brew tap ivankuznetsov/hive && brew install ivankuznetsov/hive/hive`.
- Arch Linux with `yay`: `yay -S --noconfirm --needed hive-bin`.
- Arch Linux with `paru`: `paru -S --noconfirm --needed hive-bin`.
- Ubuntu 22.04+ / glibc Linux x86_64 or aarch64:

```bash
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
curl -fsSL https://raw.githubusercontent.com/ivankuznetsov/hive/v0.2.0/install.sh -o "$tmpdir/hive-install.sh"
bash "$tmpdir/hive-install.sh"
```

After install, run the strict `hive` / `hv` version check again. If neither command prints a bare `X.Y.Z` version, stop and report that setup failed or Apache Hive may be shadowing the command. If verification succeeds, run `"${hive_cmd}" setup --json` from the current project. Summarize the installed version, setup phases, local web URL, and any diagnose-only fix commands such as `gh auth login`, `claude setup-token`, or `codex login`.

## Dispatch Rules

Treat `/hive setup`, `/hive install`, and `/hive bootstrap` as requests for the guided setup flow above. Otherwise, treat the user's slash-command text after `/hive` as arguments for `hive_cmd`. If no arguments are supplied and Hive is already installed, run `"${hive_cmd}" --help` and summarize the available workflow. Run commands from the current project/workspace directory unless the user gives another path. Pass arguments safely; do not interpolate raw user text into a shell string.

Prefer `--json` when the Hive command supports it and you need structured output. Summarize the result, including task slug, stage/action, marker, and next command when present.

OpenClaw installs and enables the Hive daemon by default, so on normal OpenClaw setups ready coding tasks usually auto-advance through stages without asking. A printed `next:` line — the command Hive suggests from command output and status hints — is a manual fallback or recovery command, not a prompt to ask the user before each ordinary stage. For normal enrolled coding tasks with the daemon running, do not ask before ordinary stage advancement; let the daemon auto-advance. Stop and ask only for actual input waits (a `needs_input` state, unanswered questions, or plan content that genuinely needs human judgment), destructive/admin confirmation, or `## Safety Boundaries` actions. When uncertain, confirm daemon state with `hive daemon status --json`; if the daemon is disabled or stopped, the project is not enrolled, the workflow is non-coding or unknown, or the user asks for manual control, present the `next:` line as an optional manual action instead of assuming auto-advance.

For `hive wiki compile-log`, prefer `--check` when verifying an aggregate wiki changelog. Run the mutating compile command only after merge/rebase or when the user explicitly wants `wiki/log.md` refreshed; feature PRs should add `wiki/log.d/<timestamp>-<slug>.md` fragments instead of editing the compiled log directly.

## Local Dogfood

Use this checklist to dogfood a merged but unreleased Hive PR against the active local runtime. Prefer a clean worktree runtime so the installed gem, package, or standalone binary stays untouched. The goal is to preserve dirty worktree state while proving the merged change locally; do not bump or release during dogfood.

1. Verify the PR is merged and green:

```bash
gh pr view <number> --json state,mergedAt,baseRefName,statusCheckRollup
```

Proceed only when `state` is `MERGED`, `mergedAt` is present, `baseRefName` is the expected main branch, and all required checks pass with none required-pending. Hard-stop when the PR is unmerged, red, or still has required checks pending.

2. Identify the active runtime:

```bash
command -v hive
readlink -f "$(command -v hive)"
hive --version
systemctl --user cat hive-daemon.service
systemctl --user show hive-daemon.service
```

Compare the interactive binary with any daemon `HIVE_BIN` or unit override. Handle the install shape that is actually active: gem/rbenv/rvm/bundler, Homebrew Cellar, Arch package, standalone binary, or a user-local wrapper.

3. Guard worktrees:

```bash
git status --short
```

Refuse to mutate any worktree with uncommitted changes. Require a separate clean checkout or clean `git worktree` for the merged PR.

4. Apply the change:

First record the prior override so rollback can restore it, not clobber it. Capture the daemon's current `HIVE_BIN` (and any drop-in `Environment=`) from step 2's `systemctl --user show hive-daemon.service` / interactive `command -v hive`; note whether an intentional override already existed and its exact value. Preferred worktree mode points the daemon override or `HIVE_BIN` at the clean merged checkout and leaves the installed binary untouched. See `## Daemon Diagnostics And Repair` for how to set `HIVE_BIN` or the unit `Environment=` via a systemd drop-in override. Patch-in-place is only a tiny single-file emergency fallback: back up the exact installed file first, then copy the changed file from the clean checkout. Do not run broad `git apply` or `cherry-pick` inside an installed package tree.

5. Run checks:

```bash
ruby -c path/to/changed_file.rb
bundle exec ruby -Itest test/path/to/focused_test.rb
```

Use the syntax check and the smallest focused or targeted test set that proves the merged change in the selected runtime.

6. Restart the daemon:

Restart with the command that matches how the override was applied. `hive daemon stop` / `hive daemon start --detach` forks a direct process that reads `HIVE_BIN` from the launching shell, so a drop-in-only `HIVE_BIN` is never picked up by this path — export the intended `HIVE_BIN` in the shell that runs `hive daemon start --detach`:

```bash
hive daemon stop
HIVE_BIN=<clean-merged-checkout> hive daemon start --detach
hive daemon status --json
systemctl --user status hive-daemon.service --no-pager
```

For a systemd-managed unit whose override lives in a drop-in `override.conf`, reload and restart the unit instead so the new `Environment=` takes effect (a newly added or edited drop-in requires `daemon-reload` first), following the restart sequence in `## Daemon Diagnostics And Repair`:

```bash
systemctl --user daemon-reload
systemctl --user restart hive-daemon.service
hive daemon status --json
systemctl --user status hive-daemon.service --no-pager
```

Stopping or restarting the daemon is guarded by `## Safety Boundaries`; restate the effect and get explicit confirmation before running guarded restart commands. Step 7's `readlink -f` / version / runtime verify confirms the restart actually adopted the intended runtime.

7. Verify behavior:

```bash
hive --version
readlink -f "$(command -v hive)"
hive daemon status --json
systemctl --user status hive-daemon.service --no-pager
```

Run one targeted smoke workflow or status check that exercises the changed behavior. Accept only when the daemon is running the intended runtime, the smoke check shows the expected behavior, and status/log output has no new terminal-error marker.

8. Rollback:

The rollback depends on the mode used. For worktree mode, restore the prior daemon override or `HIVE_BIN` captured in step 4 — set it back to the operator's intentional pre-dogfood value, or clear it only when none existed — then restart back to the intended release runtime using the step 6 restart path that matches how the override was applied. For patch-in-place mode, restore the saved backup; if the backup is untrusted, use the package-appropriate repair path such as `gem pristine`, `brew reinstall`, or reinstalling the package or standalone binary. Re-run the version, path, daemon status, and `git status --short` checks to prove the release runtime and worktrees are restored.

Guardrails: preserve dirty worktree state; do not bump or release. Dogfooding must not include `git commit`, version bumps, tag creation, gem release, package publish, destructive cleanup, or release automation.

## Status Bundle

Use this read-only bundle for a one-shot health overview; these commands need no confirmation, and this section does not weaken confirmation rules for destructive or foreground/streaming commands.

Gather:

```bash
hive daemon status --json
hive status --json
systemctl --user status hive-daemon.service --no-pager
```

For each task with a `pr_url` from `hive status --json`, derive `<number>` from the URL and run `gh pr checks <number>`; without a PR, CI is not applicable.

Summarize one bullet/block per task, not a table, with fields in this order: `stage`, `marker`, `action`, `PR URL`, `CI status`, `live PID`, `held/retry`, `suggested command`.
Source `stage`, `PR URL`, `marker`, `action`, `held/retry`, and `suggested command` from `hive status --json`; use daemon status for live PID when present, and `gh pr checks` for CI status.

Degrade gracefully: if `systemctl` is unavailable (for example macOS/launchd), report service status unavailable or use the obvious platform check.
If `gh` is missing, unauthenticated, or the task has no PR, report CI as unknown/not applicable.
If the daemon is stopped or has no live PID, report that plainly instead of failing the bundle.

## Watch Selected Tasks

Use this read-only recipe when an operator wants to wait on selected in-flight tasks and see only real state changes. It assumes `bash` 4+ (the recipe uses `mapfile`; default macOS `/bin/bash` is 3.2, so run it under a Homebrew `bash`), `jq`, and the standard `awk`, `date`, and `mktemp` utilities. It polls `hive status --json`, ignores noisy `mtime`, `folder_mtime`, and `age_seconds` churn, and uses `HIVE_WATCH_INTERVAL` (default 15 seconds) plus `HIVE_WATCH_TIMEOUT` (default 1800 seconds / 30 minutes), both env-overridable. The loop touches no Hive state: Ctrl-C is safe, it never kills Hive agents or the task's `claude_pid`, never clears markers, and never advances stages. If a loop is left running, find it with `pgrep -af 'hive status --json'` or the shell job table (`jobs`) and stop that shell job.

```bash
: "${HIVE_WATCH_INTERVAL:=15}"
: "${HIVE_WATCH_TIMEOUT:=1800}"

# Snapshot/field delimiter. Must NOT be IFS-whitespace: a tab lets `read`
# collapse empty fields (e.g. an empty marker), corrupting the stage/action/
# marker/pr_url split. Unit Separator (0x1f) never appears in Hive values.
us=$'\x1f'

tasks_jq='(.tasks // ([.projects[]?.tasks[]?]))'
if [ "$#" -gt 0 ]; then
  slugs=("$@")
else
  mapfile -t slugs < <(hive status --json | jq -r "$tasks_jq[] | select(.stage != \"9-done\") | .slug")
fi

if [ "${#slugs[@]}" -eq 0 ]; then
  echo "nothing to watch: no active (non-9-done) tasks" >&2
  exit 0
fi

snap="$(mktemp)"
cleanup() {
  rm -f "$snap" "$snap.next"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT   # 128 + SIGINT
trap 'cleanup; exit 143' TERM  # 128 + SIGTERM
: >"$snap"
started_at="$(date +%s)"
first_poll=1

state_key() {
  jq -cr '[
    .stage // "",
    .action // "",
    .marker // "",
    .attrs.phase // "",
    (.attrs.pass // "" | tostring),
    (.claude_pid_alive // "" | tostring),
    (if .held == null then "" else "\(.held.reason // "held"):\(.held.retry_after // "")" end),
    .pr_url // ""
  ]' <<<"$1"
}

state_fields() {
  jq -r --arg us "$us" '[.stage // "", .action // "", .marker // "", .pr_url // ""] | join($us)' <<<"$1"
}

# Hidden fields (phase, pass, pid_alive, held=reason:retry_after) from a
# composite key, one per line so mapfile preserves empty values by position.
hidden_fields() {
  jq -r '.[3], .[4], .[5], .[6]' <<<"$1"
}

line_for() {
  awk -F "$us" -v slug="$1" '$1 == slug { print; exit }' "$snap"
}

print_change() {
  local slug="$1" old_stage="$2" old_action="$3" old_marker="$4" new_stage="$5" new_action="$6" new_marker="$7" extras="$8"
  local old_label="${old_stage:-unknown}"
  local new_label="${new_stage:-unknown}"

  [ -n "$old_action$old_marker" ] && old_label="$old_label/${old_action:-none}/${old_marker:-none}"
  [ -n "$new_action$new_marker" ] && new_label="$new_label/${new_action:-none}/${new_marker:-none}"
  printf '%s: %s → %s%s\n' "$slug" "$old_label" "$new_label" "$extras"
}

print_final() {
  local slug="$1" stage="$2" action="$3" marker="$4" pr_url="$5"
  printf '%s: final %s/%s/%s' "$slug" "${stage:-unknown}" "${action:-none}" "${marker:-none}"
  [ -n "$pr_url" ] && printf ' pr_url=%s' "$pr_url"
  printf '\n'
}

while :; do
  now="$(date +%s)"
  status="$(hive status --json)"
  : >"$snap.next"
  terminal_count=0

  for slug in "${slugs[@]}"; do
    row="$(jq -c --arg slug "$slug" "first($tasks_jq[] | select(.slug == \$slug)) // empty" <<<"$status")"
    if [ -z "$row" ]; then
      key='["missing"]'
      new_stage="missing"
      new_action=""
      new_marker=""
      new_pr=""
    else
      key="$(state_key "$row")"
      IFS="$us" read -r new_stage new_action new_marker new_pr < <(state_fields "$row")
    fi

    old="$(line_for "$slug")"
    IFS="$us" read -r _ old_key old_stage old_action old_marker old_pr <<<"$old"

    if [ "$first_poll" -eq 0 ] && [ "$key" != "$old_key" ]; then
      # Surface hidden-field changes (phase, pass, pid_alive, held reason/retry_after)
      # that leave the stage/action/marker label identical.
      mapfile -t oh < <(hidden_fields "${old_key:-[]}")
      mapfile -t nh < <(hidden_fields "$key")
      extras=""
      [ "${oh[2]}" != "${nh[2]}" ] && extras+=" pid_alive=${nh[2]:-unknown}"
      [ "${oh[3]}" != "${nh[3]}" ] && extras+=" held=${nh[3]:-none}"
      [ "${oh[0]}" != "${nh[0]}" ] && extras+=" phase=${nh[0]:-none}"
      [ "${oh[1]}" != "${nh[1]}" ] && extras+=" pass=${nh[1]:-none}"
      print_change "$slug" "$old_stage" "$old_action" "$old_marker" "$new_stage" "$new_action" "$new_marker" "$extras"
      if [ -z "$old_pr" ] && [ -n "$new_pr" ]; then
        printf '%s: pr_url became available: %s\n' "$slug" "$new_pr"
      fi
      if { [ "$new_stage" = "7-artifacts" ] || [ "$new_stage" = "8-finalize" ]; } &&
         [ "$old_stage" != "$new_stage" ]; then
        printf '%s: entered %s' "$slug" "$new_stage"
        [ -n "$new_pr" ] && printf ' pr_url=%s' "$new_pr"
        printf '\n'
      fi
    fi

    printf '%s%s%s%s%s%s%s%s%s%s%s\n' "$slug" "$us" "$key" "$us" "$new_stage" "$us" "$new_action" "$us" "$new_marker" "$us" "$new_pr" >>"$snap.next"

    if [ "$new_stage" = "9-done" ] ||
       { [ "$new_stage" = "8-finalize" ] && [ "$new_marker" = "complete" ]; }; then
      terminal_count=$((terminal_count + 1))
    fi
  done

  mv "$snap.next" "$snap"
  first_poll=0

  [ "${#slugs[@]}" -gt 0 ] && [ "$terminal_count" -eq "${#slugs[@]}" ] && exit 0

  if [ $((now - started_at)) -ge "$HIVE_WATCH_TIMEOUT" ]; then
    while IFS="$us" read -r slug _ stage action marker pr; do
      print_final "$slug" "$stage" "$action" "$marker" "$pr"
    done <"$snap"
    exit 0
  fi

  sleep "$HIVE_WATCH_INTERVAL"
done
```

## Daemon Diagnostics And Repair

Use this when interactive `hive` works but the rootless user-systemd `hive-daemon.service` misbehaves. Run the read-only diagnostics in order before any repair so the operator can see whether the service is using the wrong binary, a missing gem environment, or a Ruby `LoadError`.

Read-only diagnostics — binary alignment:

```bash
command -v hive
hive --version
systemctl --user cat hive-daemon.service
systemctl --user show hive-daemon.service -p Environment
hive daemon status --json
```

Compare the interactive `command -v hive` path with the service `HIVE_BIN`. The expected default is the interactive binary unless the operator intentionally chose another path. A mismatch such as `/usr/bin/hive` versus `~/.local/bin/hive` usually means the daemon is not running the same Hive CLI the shell runs. When `/usr/bin/hive` appears, flag possible Apache Hive shadowing or an unintended system-package path.

Read-only diagnostics — gem and environment validation:

```bash
ruby -e 'puts Gem.user_dir'
gem env home
gem env path
printf '%s\n' "$PATH"
systemctl --user show hive-daemon.service -p Environment
```

Compare the working shell's `PATH`, `GEM_HOME`, and `GEM_PATH` with the unit's `Environment=` lines. The daemon environment is broken when it lacks the user gem dir, lacks the directory containing the intended `hive` binary, points at a different `HIVE_BIN`, or works interactively while the daemon or status path raises a Ruby `LoadError`.

Read-only diagnostics — Arch `ruby-erb` LoadError:

```text
cannot load such file -- erb (LoadError)
```

Prefer the system package fix on Arch:

```bash
sudo pacman -S ruby-erb
```

If a user-local fallback is required, install the gem and read the actual gem paths from the local Ruby rather than hardcoding a version fragment:

```bash
gem install --user-install erb
ruby -e 'puts Gem.user_dir'
gem env path
```

These commands print full gem directory paths that already contain the correct Ruby minor-version segment; copy those paths verbatim when adding `GEM_PATH` to the service environment rather than hand-assembling a version fragment.

### Safe repair (mutating)

Prefer a user systemd drop-in override instead of editing the generated unit in place. Inspect first, preserve existing `Environment=` values, and merge only the missing `PATH`, `GEM_HOME`, `GEM_PATH`, or `HIVE_BIN` entries.

`systemctl --user edit hive-daemon.service` and `sudo pacman -S ruby-erb` are interactive/operator-run: the first opens `$SYSTEMD_EDITOR`/`$EDITOR` and the second prompts for a sudo password, so both block (or no-op with no TTY) when an agent runs them non-interactively. When acting non-interactively, write the drop-in override file directly instead of opening the editor, adding only the missing `Environment=` lines:

```bash
systemctl --user cat hive-daemon.service
mkdir -p ~/.config/systemd/user/hive-daemon.service.d
cat > ~/.config/systemd/user/hive-daemon.service.d/override.conf <<'EOF'
[Service]
Environment=GEM_PATH=<derived-value>
# Add only the entries that were actually missing, e.g.:
# Environment=PATH=<derived-value>
# Environment=GEM_HOME=<derived-value>
# Environment=HIVE_BIN=<derived-value>
EOF
```

The interactive editor path stays available for an operator running this by hand:

```bash
systemctl --user edit hive-daemon.service
```

Reloading and restarting the service stops and restarts background automation, so — like `daemon stop` in `## Safety Boundaries` — restate the effect and get explicit user confirmation before running:

```bash
systemctl --user daemon-reload
systemctl --user restart hive-daemon.service
```

Verify the service is active, responding, and running with the intended binary and environment:

```bash
systemctl --user status hive-daemon.service --no-pager
hive daemon status --json
systemctl --user show hive-daemon.service -p Environment
```

If the repair changed `HIVE_BIN`, confirm it matches `command -v hive` or the operator's intentional chosen path.

## Safety Boundaries

Before running destructive admin verbs (`drop`, `uninstall`, `update`, `forget`, `prune`, `migrate`, or `metrics`), restate the effect and get explicit user confirmation. These verbs can kill agents, remove worktrees, close draft PRs, drop registry entries, or rewrite installed software — they are not undoable.

Before running nested destructive or bypass commands (`daemon stop`, `daemon disable --all`, `daemon install --force`, `bot stop`, `bot install --force`, `markers clear`, or `approve --force`), restate the effect and get explicit user confirmation. These can stop background automation, replace autostart services, clear recovery markers, or skip terminal-marker safety.

Prefer `hive daemon start --detach` for daemon startup. Before running `hive daemon start` without `--detach`, `hive daemon tail`, `hive bot start --foreground`, or `hive bot tail`, restate that the command can hold the agent in a foreground or streaming process and get explicit user confirmation.

## Marker Recovery

Inspect before acting. Use `hive status --json` as the canonical non-mutating inspection command; read `stage`, `slug`, `folder`, `state_file`, `marker`, `attrs`, `claude_pid`, `claude_pid_alive`, `live_task_lock`, `held`, and suggested-action fields before deciding. Use `hive daemon status --json` to check whether the daemon and healer are running. Fall back to `kill -0 <pid>` or `ps -p <pid>` only to double-check PID liveness, and compare `attrs.retry_after` to now for a held `limits_reached` cooldown. `hive markers clear` is mutation, not inspection.

Daemon trigger rule: if the daemon is running, wait and let the healer recover known auto-recoverable markers. If it is stopped or dead, use `hive daemon start --detach`. Do not recommend `daemon stop`, foreground daemon startup, or daemon log tailing for normal marker recovery; those commands remain governed by `## Safety Boundaries`.

Per-marker decisions:

1. `REVIEW_ERROR phase=fix reason=fix_failed message="claude stop hook did not signal completion"` -> environmental stop-hook completion failure -> let the healer auto-recover, bounded to 3 attempts; restart the daemon if it is not running; do not hand-clear. Ask first only if the healer budget is exhausted and a human wants to use manual marker clearing.
2. Generic `fix_failed` with any other message -> manual fix failure -> investigate, typically write a code fix, then re-run the task. It is never auto-cleared; the distinction from the previous entry is the byte-for-byte `claude stop hook did not signal completion` message. Ask before any marker clear.
3. `limits_reached` with a valid `retry_after` -> provider usage or credit cooldown -> wait until the cooldown elapses and let the healer requeue. Missing or malformed `retry_after` is manual. Ask before any manual clear.
4. Stale `agent_working` -> the healer classifies by child-PID liveness, so the recovery path splits: a **dead** child PID (`claude_pid_alive == false`) is rewritten to terminal `ERROR reason=agent_died`, which is not in the auto-recovery allowlist -> treat as terminal/manual and ask before clearing (do not wait for a requeue that never comes); a **missing** child PID with a stale state-file mtime is rewritten to `ERROR reason=agent_orphaned`, which the healer does auto-recover -> let the healer requeue, restarting the daemon if it is not running. A live task lock or PID alive means work is still in progress; wait.
5. Other healer-managed bounded signatures -> environmental or retryable operational failure -> let the healer retry within its budget. This includes `REVIEW_ERROR reason=review_agent_died`; reviewers `all_failed`; reviewer partial failures where every error is `tmux_session_terminated before writing expected output file`; and fix auto-commit retryable reasons `fix_auto_commit_scope_failed`, `fix_auto_commit_sign_policy_failed`, and `fix_auto_commit_signing_failed`. Ask first only after the bounded retry budget is exhausted.
6. Terminal/manual `ERROR` -> any `ERROR` whose reason is not a known healer-managed signature is terminal/manual; ask before clearing. Known healer-managed `ERROR` reasons are `limits_reached` after `retry_after`, `tmux_session_terminated`, `agent_orphaned`, `ensure_clean_on_exit_failed`, `8-finalize reason=unpushed_commits`, and `reason=timeout` only on `5-open-pr` or `7-artifacts`. Explicit manual examples are `dirty_worktree` and post-budget/exhausted `ensure_clean_on_exit_failed`; both need human worktree inspection.

For manual-clear remediation, follow the `## Safety Boundaries` confirmation rule for `markers clear`; restate the effect and get explicit user confirmation first. Canonical forms:

```bash
hive markers clear <slug> --name REVIEW_ERROR --project <project> --json
hive markers clear <folder> --name ERROR --match-attr marker_id=<id>
```

Prefer `--match-attr marker_id=<id>` when the marker has a marker id; otherwise use observed attrs such as `--match-attr reason=<reason>,exit_code=<code>`. After a confirmed clear, rerun with `hive run <slug> --project <project>` or the stage-specific retry command printed by status or review.
