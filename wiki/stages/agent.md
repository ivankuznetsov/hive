---
title: Generic Agent Stage Runner
type: stage
source: lib/hive/stages/agent.rb, lib/hive/stages/agent_worktree.rb, lib/hive/stages/agent_report.rb, lib/hive/terminal_outcome.rb, lib/hive/managed_git.rb, templates/agent_prompt.md.erb, templates/agent_worktree_prompt.md.erb
created: 2026-06-19
updated: 2026-08-02
tags: [stage, agent, workflow, terminal-outcomes, blocked]
---

**TLDR**: `Hive::Stages::Agent` is the shared headless runner for descriptor
stages whose `kind` is `:agent` and whose name does not already have a bespoke
coding runner. `Hive::Stages::Resolver` reaches it as the fallback after the
coding-name runner table. The runner resolves the active stage per-task via
`task.workflow.stage_named(task.stage_name)` (the core U6 generic behavior — NOT
the coding-pinned `Hive::Workflows::Registry.default`), renders
`templates/agent_prompt.md.erb`, resolves descriptor-level `agent`/`model`/`effort`
overrides, spawns one folder-isolated agent, and maps the resulting state-file
marker to the same commit actions as [[stages/brainstorm]]. A workflow may end
on this runner; terminal agent stages require `COMPLETE` plus a non-empty
deliverable before status reports them archived.

Stages that explicitly compose `workspace: worktree` with
`handoff: draft_pr` take a separate controller-owned path. Hive creates or
resumes the exact-origin worktree, launches the configured stage mapping once
with that worktree as `cwd`, and uses exit-code-only completion. The agent may
write repository changes plus task-root `fix-report.md`; it cannot author the
terminal Hive outcome.

## Runtime Contract

1. Resolve the stage descriptor by `task.stage_name`.
2. Use `stage.state_file` as the output and marker file.
3. Build prior context from sorted `*.md` files in the task folder, excluding the
   stage's own output file. The context is capped at 8000 characters. Each file
   read is rescued individually, so one unreadable/race-deleted artifact degrades
   to a placeholder rather than aborting the run.
4. Wrap prior context in a fresh `Hive::Stages::Base.user_supplied_tag` nonce so
   prior artifacts are treated as untrusted input.
5. Use `stage.skill` through `profile.format_skill_invocation` when present;
   otherwise use the generic "produce the best stage output" instruction.
6. Resolve the profile using descriptor `stage.agent`, then project
   `cfg[stage]["agent"]`, then `claude`. Descriptor `stage.model` /
   `stage.effort` override project Claude defaults for this spawn.
7. Spawn via `Hive::Stages::Base.spawn_agent` with `add_dirs:` from the resolved
   permission scope (`scope.fetch(:add_dirs)` — `[task.folder]` by default, but a
   `scoped` permissions block with `dirs:` appends extra directories beyond the
   task folder), `cwd: task.folder`, the descriptor's `status_mode` (falling back
   to `:state_file_marker` only when unset), and the stage profile. Descriptor
   `budget_usd` / `timeout_sec` values provide resource defaults that project
   stage config can override only when a non-null key was explicitly authored
   in the project YAML; values injected by `Config.merge_defaults` do not shadow a
   descriptor default. Timeout falls back to `DEFAULT_TIMEOUT_SEC` when neither
   source provides one. A budget is per spawn and only enforced when the
   selected profile has a native `budget_flag`; otherwise `spawn_agent` records
   the dropped cap in `config-warnings.log` while still enforcing timeout.
   Scoped file rules such as `Edit(../../../../docs/**)` are normalized from the
   task-relative descriptor form to Claude's absolute `Edit(//.../docs/**)`
   form and run under `dontAsk`, so matching writes proceed while a write
   unmatched by any loaded permission rule is denied without hanging the
   headless stage. Loaded Claude setting sources can add broader trusted
   operator allow rules; the descriptor does not erase them.
   A bounded managed Codex or Grok mapping takes a provider-portable path
   instead: the runner receives only declared read roots, runs read-only, and
   returns schema-constrained file content. Hive validates that every requested
   path is covered by a path-qualified `Edit(...)` rule and atomically
   materializes the exact output set. This lets a multi-file terminal stage
   produce both its deliverable and verification artifact without granting the
   provider direct task writes. Invalid, truncated, empty, or extra-file output
   becomes `ERROR reason=managed_output_invalid`. Controller-trusted
   `base_add_dirs` remain read-only roots in this portable path: Codex receives
   them in its named filesystem policy and Grok receives them as bubblewrap
   `--ro-bind` mounts. This is how a managed `workspace: worktree` actor can
   inspect its repository checkout. Each root must resolve to an existing
   directory or compilation fails closed, and these roots never expand the
   task-confined host output authorization.
8. Re-read `stage.state_file` and map markers: `WAITING` → `round_waiting`,
   `COMPLETE` → `complete`, `ERROR` → `error`, `NONE` → `nil` (an explicit arm —
   a markerless run has nothing to commit, so `commit_after` skips the commit),
   otherwise `marker.name.to_s`. A provider-limit error is the exception to the
   plain `ERROR` action: if `Hive::Agent` already wrote
   `ERROR reason=limits_reached`, the runner preserves that marker; if a
   non-state-file spawn only returned quota text in its error envelope, the
   runner writes the equivalent marker with the selected profile as `provider`.
   Both paths return `commit=limits_reached` and retain a `retry_after` stamp so
   the daemon cooldown healer can requeue the generic stage.
9. For a final agent stage with `terminal_outcomes`, the prompt enumerates the
   exact complete and blocked values and requires `Outcome: <value>` as the
   artifact's first line. After the runner returns `COMPLETE`, but before
   archive classification or the Hive-state commit, `Hive::TerminalOutcome`
   reads only a no-follow 513-byte window, accepts at most 512 first-line bytes,
   requires a regular file and strict UTF-8, and matches the line exactly.
   Declared complete values retain `COMPLETE`; declared blocked values become
   `ERROR reason=terminal_outcome_blocked outcome=<value>`. Missing, malformed,
   unknown, unreadable, non-regular, overlong, or invalid-UTF-8 results become
   `ERROR reason=terminal_outcome_invalid outcome=<bounded-detail>`. The error
   commit is transactional with the terminal snapshot, and never stamps
   `completed_at`. Descriptors without this opt-in keep the legacy marker path.

An error envelope does not by itself prove that the spawn wrote no marker.
`Hive::Agent` writes specific state-file errors for provider limits, timeouts,
and nonzero exits, while version/auth preflight failures return the same error
envelope without changing the file. The runner snapshots the terminal marker
before spawning. A changed marker is authoritative and retains its reason and
recovery metadata. When the marker is unchanged, a quota envelope becomes
`ERROR reason=limits_reached`; any other error envelope becomes
`ERROR reason=agent_preflight_failed`, replacing stale waiting/complete/error
state from an earlier run.

### Worktree report contract

The worktree prompt states the trusted repository, task branch, base branch,
and base OID, then wraps at most 8000 characters of sorted prior Markdown
artifacts in a fresh untrusted-data nonce. It permits a compact plan or local
debugging loop inside the one repair turn, then requires a normal committed Git
result and a bounded report with unique ordered fields: `Decision`,
`Reproduction`, `Cause`, `Changes`, `Tests`, `Risks`, and
`Suggested PR title`. Optional `Compact plan` and `Debug trace` fields may
follow. Hive markers, unknown/duplicate fields, symlinks, non-UTF-8 input, and
reports above 24 KiB are rejected.

Recoverable remote failures append a controller marker without changing the
validated report digest. Resume removes only that trailing marker, restores
the exact report bytes as validated UTF-8, and parses the same report before
continuing reconciliation; byte identity alone is not sufficient if the
returned string loses its text encoding.

After the exit, Hive verifies the recorded task branch, base ancestry, clean
state, and descendant commit count from Git itself. `ready` requires at least
one descendant commit and no diff; `no-fix` requires neither commit nor diff;
`blocked` preserves partial local evidence but is never publication authority.
Provider quota, timeout, nonzero exit, malformed output, and protected-state
violations remain runtime failures and never become report decisions. Hive
atomically replaces untrusted output with a private controller `ERROR` marker
and a non-nil commit action; quota keeps `reason=limits_reached`, timeout keeps
`reason=timeout`, and other failures use `reason=managed_agent_failed`, so a
failed task does not remain markerless and daemon-runnable.

Before and after the spawn, `Hive::ProtectedFiles` snapshots metadata, pointer,
handoff, PR/marker, journal, projection, `.git` pointer, and repository/global
Git config files. Any mutation wins over the agent result and fails closed.
All post-agent Git validation and publication runs through `Hive::ManagedGit`'s
fixed environment/config and allowlisted commands. The dedicated report is
removed by the controller before a fresh spawn and must be recreated as a
regular file.

The coding pipeline's `brainstorm` and `plan` names still use their bespoke
tmux-capable runners even though their descriptor entries are `kind: :agent`;
name-first resolver precedence preserves the current coding runtime.

## Tests

- `test/unit/stages/agent_test.rb` covers prior-artifact selection, nonce
  wrapping, nil-skill fallback, formatted skill invocation, spawn arguments,
  descriptor-versus-loaded-config resource precedence, explicit budget/timeout
  overrides, marker-to-action mapping, provider-limit envelope classification,
  preservation of fresh agent-written quota and non-quota errors, and the
  distinct unchanged-marker preflight fallback.
- `test/unit/stages/agent_report_test.rb` covers strict grammar, file safety,
  branch/ancestry verification, and `ready` / `no-fix` / `blocked` repository
  invariants. Worktree-stage cases in `agent_test.rb` cover one exact-cwd
  mapping spawn, trusted prompt identity, task/Git control-file tampering,
  symlink-safe error projection, portable repository read-root propagation,
  and provider/timeout/runtime failure markers.
- `test/unit/managed_git_test.rb` proves fsmonitor and attribute-selected
  external-diff helpers cannot execute after the agent exits.

## Backlinks

- [[modules/workflows]]
- [[stages/index]]
- [[modules/markers]]
