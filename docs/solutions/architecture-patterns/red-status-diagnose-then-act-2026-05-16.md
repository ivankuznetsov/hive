---
title: Red status diagnose-then-act surfaces for filesystem state machines
date: 2026-05-16
category: architecture-patterns
module: Hive::TaskAction
problem_type: architecture_pattern
component: recovery
severity: high
applies_when:
  - A dashboard shows red/error rows produced by a filesystem state machine
  - The next action may be automatic retry, manual worktree editing, or refreshed agent diagnosis
  - The real failure context is spread across markers, logs, and per-pass artifacts
  - Human escalation should be minimized when enough local context exists to continue automatically
tags:
  - status
  - tui
  - diagnostics
  - recovery
  - state-machine
  - agent-profile
  - marker-signature
---

# Red status diagnose-then-act surfaces

## Context

Hive tasks advertise their state through marker comments in stage files and through sidecar artifacts such as `reviews/errors-NN.md`, `reviews/escalations-NN.md`, CI-fix logs, implementation logs, and worktree metadata. That file-first model is strong for auditability, but it created a weak operator surface for red rows: the grid could show `Needs recovery` or `ERROR exit_code=1` while the useful explanation sat elsewhere.

The bad UX pattern is "checkbox escalation as status." A checkbox tells the user something is blocked, but not:

- why the system stopped;
- which local evidence was already checked;
- whether the next step should be automatic retry;
- whether manual code editing is needed;
- whether an agent could answer the question from current context.

The stronger shape is diagnose-then-act: put the best available explanation next to the action buttons, default to auto-fix when the row is recoverable, and reserve user input for cases where local context is genuinely insufficient.

## Pattern

### 1. Put a nullable diagnostic on every status row

Add a required `diagnostic` field to the machine-readable status row, with `null` for normal rows and an object for red rows. Required-and-nullable follows Hive's schema policy from ADR-025: every producer emits the field, and consumers never have to guess whether absence means "old producer" or "no diagnosis."

The object should be deliberately small and stable:

- `summary`: short marker-level explanation.
- `detail`: bounded evidence tail.
- `source` / `source_path`: artifact vs marker fallback.
- `artifact_paths`: exact files inspected.
- `generated_by`: `local` or the profile that wrote a diagnosis artifact.
- `updated_at`: when this explanation was sourced.

Use a local extractor first. It should be deterministic, bounded, and safe to run during every status poll.

### 2. Prefer local artifacts before asking an agent

Marker-specific artifact selection keeps the first answer cheap:

- `REVIEW_ERROR`: pass error file, fix-guardrail file, escalations file, marker `files=...`, phase logs, latest logs.
- `REVIEW_CI_STALE`: CI-blocked artifact and CI-fix attempt logs.
- `REVIEW_STALE`: pass escalations/reviewer files and logs.
- `EXECUTE_STALE`: review files and logs.
- `ERROR`: latest logs and the state file.

Always secret-redact diagnostic text with the same patterns used elsewhere in the publishing pipeline.

### 3. Let a headless agent enrich diagnosis without owning workflow state

Provide an explicit command for richer diagnosis:

```bash
hive status --diagnose <task> --write
```

This command may spawn the configured development agent, but it must not claim the task lock, clear markers, or advance stages. It writes one artifact: `<task>/diagnostics/red-status.md`.

Use the same profile selection as implementation (`execute.agent`) so the operator's configured development tool answers the question. In Hive this is `Hive::Stages::Base.stage_profile(cfg, "execute")`. Give the agent the task folder as context and run from the worktree when available.

### 4. Trust diagnosis artifacts only when they match the current marker

Agent-written diagnosis can go stale the moment a retry writes a new marker. Protect the read path with frontmatter:

```yaml
---
generated_by: codex
marker_signature: <sha256 marker name + sorted attrs>
diagnosed_at: 2026-05-16T00:00:00Z
---
```

Normal status should trust the artifact only if:

- `generated_by` is `local` or a registered profile name;
- `marker_signature` matches the current marker;
- the frontmatter parses.

If any check fails, ignore the artifact and fall back to local extraction.

### 5. Make the TUI view a Q&A action surface

For ambiguous red rows, grid Enter should open a detail view, not immediately mutate state. The detail view should answer:

1. Why is this red?
2. What can Hive do next?

Then offer explicit actions:

- `Enter`: existing autofix/retry path.
- `f`: open worktree in `$EDITOR` for manual fix.
- `R`: refresh diagnosis via the headless command.
- `q`/`Esc`: return.

Preserve direct paths for deterministic states where a detail view would add friction:

- wall-clock review stale retry;
- max-passes review stale with an existing escalations file, where the correct first move is browse/edit that file;
- kill-class signal errors, where auto-heal is already clearing the interruption marker;
- states with no autofix action in v1.

## Why this matters

The operator should not have to parse logs to decide whether Hive can continue. The status row already knows the task folder, marker, attrs, action kind, and stage; it can gather the relevant artifacts and make the next move legible.

The same diagnostic object also gives bots, daemons, and future agents a stable contract. They can decide whether to auto-fix, ask the user, or run fresh diagnosis without scraping terminal text.

## Testing

Cover the pattern at three layers:

- `TaskAction` tests for artifact selection, stale-artifact rejection, marker fallback, and redaction.
- Status command tests for local `--diagnose` and `--diagnose --write` preferring a fresh artifact.
- TUI tests for red-detail gating, detail-mode keybindings, manual fix editor handoff, background diagnosis dispatch/dedup, and snapshot updates that close or refresh the detail view.

## Related

- `wiki/commands/status.md` - command contract and JSON payload shape.
- `wiki/commands/tui.md` - operator-facing red-status detail flow.
- `wiki/decisions.md` ADR-027 - Hive-specific decision record.
- `docs/solutions/architecture-patterns/background-spawn-and-signal-aware-marker-healing-2026-04-28.md` - prior recovery pattern for deterministic kill-class errors.
