# FAQ

## Why Not X

### Why folders, not a database or tracker?

Hive needs state that any editor, shell, or git command can inspect. Folder location, markdown files, and git commits keep the queue portable and auditable.

### Why per-stage agent subprocesses, not a long-running orchestrator?

Each stage has a small contract and a fresh process boundary. That keeps prompts scoped, logs separated, and retries tied to the current folder state.

### Why commit `.hive-state/` to a separate `hive/state` branch?

Hive state changes often and should not pollute the project's code history or trigger normal CI. The orphan branch keeps task history durable without adding `.hive-state/` to `main`.

### Why both `mv` and `hive approve`?

`mv` is the primitive. `hive approve` wraps the same transition with marker validation, locking, commits, retry checks, and JSON output.

### Why project-level daemon enrollment?

The daemon service is installed as global user infrastructure so it survives login and reboot. Project enrollment stays explicit because the daemon can spend real agent time and move many tasks; `daemon.enabled: true` is the durable consent signal for a specific repository, and `--dry-run` lets you inspect dispatches before live mode.

### Why no built-in web UI?

The core interface is the filesystem and CLI. A web UI would add another state surface before the file protocol is finished.

### Why more than one agent?

Hive treats agent CLIs as profiles. Planning, implementation, review, and browser testing can use different tools because their strengths and output contracts differ.

## Troubleshooting

### `already initialized`

Cause: the project already has a `hive/state` branch. Fix: skip `hive init` or use the existing `.hive-state/`. Exit code: 2.

### `not a git repository`

Cause: `hive init` ran outside a git checkout. Fix: run `git init` or move into the project root.

### `uncommitted modifications to tracked files`

Cause: `hive init` refuses to bootstrap over tracked local edits. Fix: commit, stash, or rerun with `hive init --force` when you accept the risk.

### `plan.md missing` in `4-execute`

Cause: the task skipped `3-plan/`. Fix: move it back through plan, then run `hive develop` again.

### `no worktree pointer`

Cause: a PR, review, finalize, or archive stage was reached without execute writing `worktree.yml`. Fix: move the task back through execute.

### `worktree pointer present but worktree missing`

Cause: the feature worktree was deleted. Fix: run `git -C <project> worktree prune`, delete the stale `worktree.yml`, then re-run execute.

### `slug ... is ambiguous`

Cause: the same slug exists in multiple projects or stages. Fix: pass `--project <name>`, `--from <stage>`, `--stage <stage>`, or a full task folder path.

### `no finding with id=...`

Cause: the selected finding ID does not exist in the current review file. Fix: run `hive findings <slug>` again and use the listed IDs.

### `no findings selected`

Cause: `accept-finding` or `reject-finding` got no selector. Fix: pass IDs, `--severity <name>`, or `--all`.

### `hive doctor` reports a missing or stale managed skill

Doctor never installs anything. Run `hive setup-agents` to see one aggregate
preview and confirm once, or use `hive setup-agents --yes --json` only in an
already-authorized unattended flow. You can scope repair with
`--agent claude --skill ce-brainstorm`; the exact command is printed in the
doctor row.

### `hive doctor` reports `conflicting`

Hive found a user-owned alias, marketplace/plugin source, or a higher-priority
skill path that would win runtime resolution. Setup intentionally leaves it
untouched. Follow the row's manual remediation: remove or rename the shadow if
you own it, or update the Hive config to invoke your custom skill. Do not
overwrite the reported file merely to make setup green.

### An agent is `unavailable`

Hive does not install or authenticate agent CLIs. Unavailable rows are visible,
non-blocking skips; install/log in to that agent separately and rerun setup.
Failures for one available agent do not roll back successful independent
operations for another, and a rerun schedules only unresolved work.

### Stale `.lock`

Cause: a prior run left a lock file. Fix: re-run the command; Hive clears stale locks when the recorded PID is dead and the PID-reuse check passes.

### `REVIEW_STALE` in `task.md`

Cause: review hit `review.max_passes` or the wall-clock cap. Fix: inspect `reviews/escalations-NN.md` or reviewer files, then run `hive markers clear <folder> --name REVIEW_STALE` and `hive run <folder>`.

### `REVIEW_CI_STALE` in `task.md`

Cause: the CI-fix phase exhausted its attempts. Fix: inspect `reviews/ci-blocked.md`, fix CI, clear the marker with `hive markers clear <folder> --name REVIEW_CI_STALE`, then re-run.

### `REVIEW_ERROR` in `task.md`

Cause: a review phase failed or protected-file tampering was detected. Fix: inspect `task.md`, `logs/`, and `reviews/`, clear with `hive markers clear <folder> --name REVIEW_ERROR`, then re-run.

If the marker is `phase=fix reason=fix_failed` and the message says
`claude stop hook did not signal completion`, it may be the tmux Stop-hook
failure covered in [recipes](recipes.md#recover-a-tmux-review-fix-stop-hook-timeout).
Clear only with `--match-attr phase=fix,reason=fix_failed` after verifying
the review artifacts and fix commit/no-change evidence. `claude.mode:
headless` is still the safest workaround on affected versions.

### `reviewer_tampered`, `triage_tampered`, or `fix_tampered`

Cause: an agent changed a protected file such as `plan.md`, `worktree.yml`, or `task.md` during a phase that must not touch it. Fix: inspect the worktree, restore the protected file from git if needed, clear the error marker, and re-run.

### Concurrent `hive run`

Cause: another live process owns the task lock. Fix: wait for it to finish, or stop the other process if you know it is stuck.

## First Aid

Run:

```bash
hive doctor
hive status
hive status --json
```

`hive doctor` checks missing stage and reviewer skills. `hive status` tells you the next safe command for each task.
