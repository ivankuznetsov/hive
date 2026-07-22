---
title: hive babysit
type: command
source: lib/hive/cli.rb, lib/hive/commands/babysit.rb, bin/hive-babysitter-stub-git, bin/hive-babysitter-stub-gh
created: 2026-05-26
updated: 2026-07-22
tags: [command, babysitter, daemon, github]
---

**TLDR**: `hive babysit` manages the experimental PR babysitter. It is a separate process from `hive daemon`: it polls open PRs for projects with `babysitter.enabled: true`, skips ignored labels, and asks the configured development agent to repair conflicts or red CI in an isolated PR worktree.

## Usage

```bash
hive babysit start [--detach] [--dry-run]
hive babysit stop
hive babysit restart [--detach] [--dry-run]
hive babysit status
hive babysit reload
hive babysit tail
hive babysit --once PROJECT [--dry-run]
hive babysit --once --all [--dry-run]
```

The command is bare-text in v1; it does not emit a `--json` envelope.

## Lifecycle

`start` writes `$HIVE_HOME/.babysitter.pid` and runs `Hive::Babysitter::Dispatcher`. The PID payload mirrors `hive daemon`: YAML with `pid`, `process_start_time`, and `started_at`, guarded against PID reuse through shared `Hive::PidFile` helpers. PID reservation and cleanup are serialized by a bounded sidecar lock so `start` cannot replace the PID file while `stop` is comparing and unlinking it, and lifecycle commands fail with a diagnostic instead of hanging forever on a wedged lock holder. `stop` sends TERM, waits up to 600 seconds, then escalates to KILL when ownership can still be verified; the long drain protects active PR repair agents and their temporary worktrees. If ownership becomes reused/unverified, or if the process remains alive after KILL, `stop` leaves the PID file for operator inspection and exits with an error instead of reporting a clean stop. Successful stop cleanup removes the PID file only when it still matches the payload being stopped, so a concurrent replacement `start` cannot lose its freshly-created PID lock. `restart` stops an existing process when the PID file exists and aborts if that stop path deliberately leaves a potentially live PID behind; otherwise it starts a new process. For `restart --detach`, it resolves the stable user-facing Hive wrapper with `Hive::InvokedBinary.path` and re-execs `hive babysit start --detach` before daemonizing so the live process and PID file are not stranded under a stale `restart --detach` argv. `reload` sends HUP, and `status` reports running/not-running plus uptime.

`reload` is only a config/log-settings refresh; it does not reload Ruby code into an already-running detached process. `status` compares the PID-file `started_at` timestamp with the latest mtime under `bin/hive`, `lib/hive.rb`, and `lib/hive/**/*.rb`. When the process predates the current source checkout, `status` prints a restart recommendation and `reload` warns the operator to run `hive babysit restart --detach` instead.

The log file is `$HIVE_HOME/logs/babysitter.log`, written by `Hive::Babysitter::Logger` as rotated JSON lines using the same global log-size knobs as the daemon.

`--once PROJECT` runs one dispatcher tick for the named registered project. `--once --all` runs one tick across every enabled registered project. These paths are intended for smoke tests and manual dry-run checks.

## Project Contract

Per-project config lives in `<project>/.hive-state/config.yml`:

```yaml
babysitter:
  enabled: true
  interval: 10m
  max_concurrent_prs: 2
  labels_ignore: [wip, do-not-merge, draft]
  dry_run: false
  auto_rebase: true
  budget_minutes: 30
  budget_usd: 50
```

`ProjectTick` reloads the project config on every tick, so changing `babysitter.enabled: false` is the kill switch and takes effect within one poll interval. `interval` accepts integer seconds or strings like `10m`, `30s`, and `1h`. `auto_rebase` (default `true`; `false` disables) controls auto-rebasing green-but-`BEHIND` PRs — see PR Processing below.

## PR Processing

For each enabled project, the babysitter:

1. Runs `gh pr list --state open` through `Hive::Gh.list_open_prs`.
2. Skips draft PRs before worktree materialization.
3. Skips PRs whose labels intersect `labels_ignore` case-insensitively.
4. Skips PRs already in the in-process in-flight set.
5. Sorts by actionability (`DIRTY`/`BLOCKED`/`UNSTABLE`, then `BEHIND`/`UNKNOWN`, then neutral) with `updatedAt` as the tie-breaker, and truncates to `max_concurrent_prs`.
6. Runs `Hive::Babysitter::PrFixer` on each selected PR.

`PrFixer` first checks `gh pr view --json mergeable,mergeStateStatus,statusCheckRollup`. If the PR is mergeable and checks are successful or queued (green), it normally records a `noop`/`already-green` event and does not spawn an agent. The exception: a green PR whose `mergeStateStatus` is `BEHIND` cannot merge under strict "branch must be up-to-date" protection. When `auto_rebase` is enabled (default), `PrFixer#handle_green` materializes the PR worktree, runs `GhOps.rebase_onto_base` (resolve `git remote get-url --push origin`, fetch `<base>` from that source with fallback to `origin`, then `git rebase FETCH_HEAD`), and on a clean rebase force-pushes the rebased HEAD to the PR's **real head branch** (`headRefName`, not the internal `hive-babysitter/pr-<n>` worktree branch) with an explicit `--force-with-lease=<headRefName>:<headRefOid>` so the PR becomes `CLEAN`/mergeable (emits `rebase`/`success`, counted as `fixed`). A rebase that conflicts is aborted and left for a human: no force-push, no fix agent, no label (emits `rebase`/`conflict`, counted as `needs_human`); it is re-evaluated cheaply on the next tick. With `auto_rebase: false` a green-but-`BEHIND` PR just `noop`s. If the PR is not green, `PrFixer` materializes the worktree, gathers failing-job logs plus diff stats, renders `templates/babysitter_pr_fix_prompt.md.erb`, and spawns the configured `execute.agent` through `Hive::Stages::Base.spawn_agent` with `status_mode: :exit_code_only`.

On success, the babysitter is silent on the PR. On failure, timeout, or budget exhaustion it applies `babysitter/needs-human` and posts one give-up comment per PR per UTC hour.

## Dry Run

Current Patrol hardening supersedes older wording below: authenticated `gh` reads copy only a
validated `hosts.yml` into a fresh private directory for each invocation, set
`GH_PROMPT_DISABLED=1`, and remove that directory when `gh` exits; invalid handoffs get an empty
directory, and executable `config.yml` settings are never copied. Working-tree `git diff` is
default-denied because clean/process filters can execute repository code. Allowed Git reads
require Git 2.45+ and use `--no-lazy-fetch`; creation or replacement races on the skip log are
rejected and warned rather than retried.

`--dry-run` sets the dispatcher dry-run flag. The agent prompt tells the agent to write `.babysitter-dry-run-plan.md` instead of mutating GitHub, spells out the read-only `git`/`gh` allowlist, and warns that a blocked command returns synthetic success: stderr is the primary signal, while the skip log is best-effort and may be absent when its target is unsafe or unavailable. `Hive::Babysitter::DryRunEnv` prepends a PATH overlay where `git` and `gh` point at babysitter wrapper launchers. The launchers pin absolute realpaths for the parent-resolved real binaries and the worktree-root skip-log path before invoking the shared stubs, and inherited dynamic-loader env (`LD_*` / `DYLD_*`) is scrubbed before overlay handoff, so command-local `HIVE_BABYSITTER_REAL_GIT` / `HIVE_BABYSITTER_REAL_GH` or `HIVE_BABYSITTER_DRY_RUN_LOG` overrides cannot redirect allowlisted passthrough or skipped-command audit records. They also cover direct `gh` stub execution: the installed `gh` stub is a shell launcher that clears Ruby/Bundler/Gem startup env and common dynamic-loader env before loading `bin/hive-babysitter-stub-gh.rb`, and the Ruby guard repeats that scrub before execing real `gh`. The shared stubs exit 127 when the real-binary handoff is unset or non-absolute, so a relative `bin/git` or `bin/gh` value cannot be re-resolved inside the PR worktree. Before an allowlisted `gh` passthrough, the shared stub deletes command-local config/home/host env plus the private config handoff env, pins `PATH=/usr/bin:/bin`, then points both `HOME` and `GH_CONFIG_DIR` at a fresh empty temp dir so the real `gh` has a writable state location without reading caller/user config or resolving child `git` helpers from caller-controlled directories. The stubs are default-deny: they strip safe leading global path/repo options, reject unsafe global options, pass through only known read-only commands, screen exec/write-capable options in the regions where the real CLI honors them, and skip anything mutating or unknown while attempting to append the skipped invocation to `.babysitter-dry-run-skipped.log`. For `gh`, only bare `OWNER/REPO` selectors (`-R`, `--repo`, `--repo=...`) are stripped before allowlist classification; host-qualified repo selectors, URL/scp-style selectors, `--hostname` selectors anywhere in argv, and host-carrying `repo view` / PR URL positionals are logged/skipped.

Skip logging itself is guarded: `DryRunEnv` first creates the worktree-root audit log as an owned private regular file before any agent command can become a concurrent first writer; an existing target is never modified during setup and remains subject to the stubs' checks. Both stubs preflight an existing `HIVE_BABYSITTER_DRY_RUN_LOG` target (or the default `.babysitter-dry-run-skipped.log`) with `File.lstat`, reject non-regular/non-owned targets before opening, then open with `File::NOFOLLOW` and `File::NONBLOCK`, verify that the opened descriptor has the preflighted device/inode, and re-check it before writing. A direct stub invocation with a genuinely missing log still creates it as mode `0600` with `File::EXCL`; creation or replacement races remain rejected and warned. FIFOs, symlinks, devices, hard links, ownership mismatches, and pathname swaps warn instead of blocking or writing. The skipped command still exits successfully after that warning so dry-run behavior remains default-deny even when the audit sink is unsafe or unavailable. Logged and stderr-rendered argv is scanned byte-by-byte: ASCII control bytes are escaped as `\xHH`, invalid/non-UTF-8 bytes do not crash `log_skip`, and high bytes pass through unchanged, so a skipped argument containing a newline cannot forge extra log lines. Escaped argv is capped at 4 KiB with a truncation marker. An exclusive lock serializes each append and its 64 KiB size check; when the next complete record would exceed the cap, the existing audit history is preserved and the usual best-effort write warning is emitted. Lock acquisition uses a short monotonic deadline so a stalled writer cannot hang a denied command.

The current `git` stub read-only allowlist is exact read forms for `branch` (bare, `--show-current`, `--contains`, `--contains <rev>`, or `--contains=<rev>`), `cat-file`, `describe`, `diff`, `grep`, `log`, `ls-files`, `ls-tree`, `merge-base`, `remote` only for listing, `remote show -n <remote>`, `remote get-url` forms, `rev-list`, `rev-parse`, `show`, `status`, and `config` when paired with `--get`, `--get-all`, or `--list`. Even for allowlisted commands, the stub skips executable-affecting options first. Global config overrides are rejected wholesale: **any** leading `-c` / `--config-env` (glued or separate) is treated as unsafe, because git keeps adding exec-capable keys (`diff.external`, `diff.<driver>.textconv`/`command`, `filter.<driver>.clean`/`smudge`/`process`, `gpg.<format>.program`, pagers, hooks, aliases, protocol/include helpers, ...) and rejecting the whole config-override category is more robust than enumerating each dangerous key. The stub also skips leading global pager/exec-path switches (`--paginate`/`--exec-path`, scoped to the global-option region so a read-only subcommand `-p` like `git log -p` still passes), and the command options `--help`, `--man`, `--web`, `--html`, `--info`, `--ext-diff`, `--textconv` (full spelling plus Git's unambiguous long-option prefixes), `--remerge-diff` / `--diff-merges=remerge` / `--diff-merges=r` on `log` or `show` (replays merge machinery and honors repo-local merge drivers), the grep-only `--open-files-in-pager` (full spelling plus Git's unambiguous long-option prefixes down to `--op`, and the `-O` short form, glued, separate, or clustered - on `diff`/`log`/`show`, `-O` is the read-only `--output-ordering` and stays allowed), and the file-writing `--output` / `-o`. The help/manual dispatch options are skipped because `git <command> --help` routes through `git help` and can execute repo/user configured manual, web, or info viewers. The grep short-cluster scanner stops when value-taking options such as `-e`, `-f`, `-m`, `-A`, `-B`, or `-C` consume the rest of the token, so read-only patterns like `git grep -eTODO` are not skipped merely because their operand contains uppercase `O`. The file-write guard is scoped past `grep`, so `git grep -o` / `--only-matching` stays allowed, and past `git ls-files -o` / `--others` (a read), while the long-form `--output` write still skips; option scanning stops at the `--` pathspec separator so `git log -- -o` reads a file literally named `-o`. `git cat-file --filters` is skipped because the `--filters` mode runs configured clean/smudge filter programs. `git log` / `git show` `--show-signature` and `log` / `show` / `rev-list` `--format` or `--pretty` values containing `%G` are skipped because signature verification runs configured GPG helpers. Because the same exec-capable config can arrive through git's environment, the stub also mirrors the `-c` rejection onto the env path, fail-closed: it skips when any of `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_GLOBAL`, or `GIT_CONFIG_SYSTEM` is set, or when `GIT_CONFIG_COUNT` is set to anything that does not cleanly parse to `0` (a positive count carries attacker-controlled `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n`; a non-numeric value is rejected by default-deny). This is a denylist of git's known exec-capable env seams rather than an exhaustive bar. Before an allowed `git` read execs the real binary, the stub neutralizes `HOME` and `XDG_CONFIG_HOME`, disables system/global git config, points `GIT_CONFIG_GLOBAL`/`GIT_CONFIG_SYSTEM` at `/dev/null`, sets `GIT_OPTIONAL_LOCKS=0`, clears trace/config/SSH/pager and dynamic-loader (`LD_*` / `DYLD_*`) env seams, prepends `-c core.fsmonitor=false`, `-c core.askPass=`, `-c log.showSignature=false`, and `-c log.diffMerges=separate`, and injects `--no-ext-diff --no-textconv` for `diff`, `log`, and `show`; local `.git/config` cannot re-enable external diff, textconv, fsmonitor, log-triggered signature verification, or config-resolved remerge diffs during dry-run passthrough. `GIT_PAGER` / `core.pager` is left unguarded for the skip decision because non-TTY dry-run stdout does not auto-spawn a pager, though the pager env is scrubbed before passthrough. The current `gh` stub read-only allowlist is `api` with no mutating method and no payload flags, `api --method GET ...` / `api -XGET ...`, non-token host-default `auth status`, `pr checks/diff/list/status/view`, `run list/view/watch`, `repo view`, and `workflow list/view`. Host selectors are excluded even when followed by an otherwise allowlisted read, because they can redirect authenticated traffic to an agent-chosen host.

Pager note (2026-06-19): allowlisted `git` passthrough now also deletes `PAGER` with `GIT_PAGER` and forces `--no-pager` on the real git invocation, so a repo-local `core.pager` cannot execute even when stdout is a TTY. Pager env/config remains non-fatal for the skip decision; it is neutralized only after the command has passed the read-only gate.

Current source/test coverage also includes `GIT_EXEC_PATH`, `GIT_ASKPASS`, and `SSH_ASKPASS` in the fail-closed git env guard; they are part of the dry-run boundary, not optional hardening. The dry-run overlay and both stubs now scrub dynamic-loader env (`LD_PRELOAD`, `LD_LIBRARY_PATH`, `LD_AUDIT`, `LD_DEBUG_OUTPUT`, `DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, `DYLD_FALLBACK_LIBRARY_PATH`) before the Ruby stub handoff and before real `git` / `gh` passthrough.

For `gh api`, payload-bearing forms are treated as writes unless the command explicitly sets GET. Dry-run skips implicit-POST calls such as `gh api repos/owner/repo/issues/123/comments -f body=hi`, `-F body=@comment.md`, `--raw-field body=hi`, `--field body=hi`, and `--input payload.json`, while still passing explicit GET reads such as `gh api --method GET repos/owner/repo/issues -f state=open`. Explicit GET file/input payloads and cache writes (`-F q=@secret`, glued `-Fq=@secret` / `-F=q=@secret`, `--field=q=@secret`, `--input=payload.json`, `--cache`, and `--cache=<ttl>`) still skip. Browser-launch flags (`--web` and short `-w` parsed as an option flag on read-only PR/repo/run/workflow commands) also skip. The short-option scanner is command-aware and honors value-taking options, so `w` inside values like `gh pr diff 42 -eworkflow.yml`, `gh pr list -lwip`, `gh pr view 42 -qweb`, or `gh pr list --search -wip` passes through instead of being mistaken for a browser launch. For `gh auth status`, `--show-token`, `--show-token=...`, bare `-t`, clustered boolean shorthand forms containing `t` before a value-taking `h` (for example `-at`, `-ta`, and `-ath`), and every host selector (`-h github.com`, `-hgithub.com`, `-ah github.com`, `--hostname`, and `--hostname=...`) skip, while host-default non-token reads such as plain `gh auth status` and `-a` pass through. Before any allowed `gh` read execs the real binary, pager/browser/editor/TTY env is scrubbed, command-local `GH_CONFIG_DIR` / `XDG_CONFIG_HOME` / `HOME` is neutralized, `GH_HOST` / `GH_REPO` / enterprise-token env is deleted, and both `HOME` and `GH_CONFIG_DIR` are pointed at the run-scoped hosts-only auth view. If the trusted handoff is absent or invalid, the stub falls back to a fresh empty writable temp directory rather than caller-controlled config.

The API classifier consumes every known value-taking option before deriving the method and payload state. In particular, a separate `-XGET` value belonging to `--header`/`-H`, `--jq`/`-q`, `--preview`/`-p`, or `--template`/`-t` is data rather than an explicit method, so a following scalar field remains an implicit POST and is skipped.

The dry-run guard is best-effort: an agent that invokes absolute binary paths can bypass the PATH overlay. Use throwaway repos for destructive validation until a stronger sandbox exists. If `HIVE_BABYSITTER_REAL_GIT` is unset or points at an invalid binary, the stub exits 127 with a one-line diagnostic instead of guessing a system path.

Existing skip logs must already be private: both the pre-open and post-open
checks reject any file with group or world permission bits. The blocked command
still returns synthetic success and emits the stderr marker plus an audit-write
warning, but the permissive file is left untouched and receives no new argv.

### Queued dry-run launcher consolidation

Queued commit `9c4b4d69` on `fix/all-worthy-patrol-findings` removes the
separately packaged `bin/hive-babysitter-stub-gh` shell file. Its generated
overlay invokes `bin/hive-babysitter-stub-gh.rb` directly through the resolved
Ruby executable, while `Hive::Babysitter::StubEnvironment` supplies the shared
Ruby/Bundler startup list and a catch-all `LD_*` / `DYLD_*` scrub to the parent,
generated launchers, Ruby stubs, and real-command passthrough. The skip logger
returns the single escaped message used for both audit output and stderr, and
allowlisted git passthrough additionally clears `GIT_PROXY_COMMAND`.

The queued git classifier also blocks `rev-list --show-signature`. Exact
`--text` remains a read option for `diff`, `log`, and `show`, while textconv
abbreviations and `cat-file`/`grep --text` stay denied at this boundary. The
current default still packages the shell launcher, so this subsection is a
branch projection rather than the installed command contract.

## Tests

- `test/unit/commands/babysit_test.rb` covers CLI flag validation, lifecycle helpers, foreground `restart`, detached restart re-exec into `start --detach`, stale-runtime status recommendations, stale-runtime reload warnings, refused-stop failures, PID-file cleanup races, and bounded PID-lock behavior.
- `test/unit/babysitter/dry_run_env_test.rb` includes a PTY-backed `git log` regression with `PAGER`, `GIT_PAGER`, and repo-local `core.pager` pointed at a marker-writing helper; the marker must not be created because dry-run passthrough forces `--no-pager`. It also configures a repo-local `man.viewer` helper and asserts `git status --help` is skipped before that helper can run.
- `test/unit/babysitter/*_test.rb` covers interval parsing, dispatcher ticks, PR filtering, context building, PR fixing, GitHub ops, worktree materialization, and dry-run PATH wrappers, including command-local `HIVE_BABYSITTER_REAL_*` and `HIVE_BABYSITTER_DRY_RUN_LOG` override resistance, `gh` passthrough `HOME`/`GH_CONFIG_DIR` tempdir isolation against command-local `HOME` / `GH_CONFIG_DIR` / `XDG_CONFIG_HOME` / `HIVE_BABYSITTER_TRUSTED_GH_CONFIG_DIR`, argv-wide and positional `gh` host-override skips, `GH_HOST` / `GH_REPO` / enterprise-token env scrubbing, the `gh api` implicit-POST payload flag guard, explicit-GET file/cache guards, non-token host-default `gh auth status` passthrough with token and hostname flag skips, browser-launch flag skips plus `w` inside value-taking `gh` read options, git executable/write-option skips, plain `git remote show <remote>` skipping before configured transport helpers can run, exact read-only `git branch` forms versus mixed branch mutation flags, subcommand `-p` passthrough, grep/`ls-files` read-option exceptions, grep pager `--open-files-in-pager` abbreviations and `-O` forms including clustered `-nO<cmd>`, value-taking grep short options such as `-eTODO` / `-fNEEDLEFILE.txt`, `--textconv` abbreviation and `cat-file --filters` skips, remerge-diff option skips plus `log.diffMerges=separate` passthrough hardening against merge-driver execution, signature-verification skips and `log.showSignature` passthrough override, pathspec separator handling, env config/command seams such as `GIT_EXTERNAL_DIFF`, `GIT_SSH_COMMAND`, `GIT_SSH`, `GIT_PROXY_COMMAND`, `GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT`, `GIT_CONFIG_GLOBAL`, `GIT_CONFIG_SYSTEM`, `GIT_EXEC_PATH`, `GIT_ASKPASS`, and `SSH_ASKPASS`, HOME/XDG/local `.git/config` hardening for allowed git reads, symlinked skip-log refusal, FIFO skip-log refusal without blocking, and ASCII control-character escaping in skip logs and stderr. It does not currently pass deliberately invalid/non-UTF-8 argv bytes into either stub.
- `test/babysitter/run.rb` runs the acceptance smoke suite for early-green, ignored-label, dry-run, and give-up paths.

## Backlinks

- [[cli]]
- [[modules/babysitter]] · [[modules/config]] · [[modules/agent_profile]]
- [[operating]]
