---
title: Hive::DiagnosisAgent
type: module
source: lib/hive/diagnosis_agent.rb
created: 2026-05-16
updated: 2026-05-19
tags: [module, status, diagnostic, agent, recovery]
---

**TLDR**: Headless one-shot spawn of the project's configured execute AgentProfile (claude / codex / pi) whose sole purpose is producing a human-readable verdict on a red task's marker state. Writes the result to `<task.folder>/diagnostics/red-status.md`, which `Hive::TaskAction#diagnostic` then prefers over its local bounded extraction. Invoked by `hive status --diagnose <slug> --write` (CLI) and by the TUI red-status detail view's `R` key.

## Public surface

```ruby
Hive::DiagnosisAgent.run!(task: hive_task, local_diagnostic: local_payload_hash_or_nil)
# => absolute path to the written diagnostics/red-status.md
# raises Hive::DiagnosisAgent::StaleMarker when the marker rotates mid-spawn
# raises Hive::AgentError / Hive::Error on profile preflight / spawn / timeout / non-zero exit
```

`local_diagnostic` is the TaskAction local-extraction payload (matching the `Diagnostic` JSON shape). It is folded into the prompt under an ADR-019 nonce-wrapped block so the agent has the operator's own first-pass summary as context.

The instance form `DiagnosisAgent.new(task:, local_diagnostic:, spawn:)` accepts a `spawn:` callable for tests; injecting a spawn skips `profile.check_version!` / `profile.preflight!` because those validate the OS-level binary which is irrelevant to a test double and missing on stock CI runners.

## Invariants

This class is deliberately NOT a `Hive::Agent#run!` subclass. Diagnose has different load-bearing invariants than a workflow-verb spawn:

- **No marker writes.** Diagnose never sets `:agent_working` pre-spawn or any terminal marker post-spawn. The run is observation-only; the marker state it explains is the same state present at completion. See ADR-027.
- **No task lock.** Diagnose does not call `Hive::Lock.with_task_lock`. A concurrent `hive run` on the same task must remain possible while diagnose is in flight; staleness is handled by the freshness gate, not by serialisation.
- **No stage advance.** Diagnose never moves the task folder between stages.
- **Bounded budget.** `DEFAULT_TIMEOUT_SECONDS=600`, `DEFAULT_BUDGET_USD=5`, capped at spawn time via the profile's `extra_flags` builder.
- **pgroup-scoped cleanup.** Spawn uses `Open3.popen3(*cmd, pgroup: true)` plus a manual wait loop. On timeout we send `SIGTERM` to the process group, wait `TERMINATE_GRACE_SECONDS=5`, then `SIGKILL`. The previous `Timeout.timeout` shape unwound the popen3 block without signalling the child and left the orphan burning API budget for the rest of the session.
- **Validated cwd.** Diagnose resolves the task's worktree pointer through `Hive::Worktree.validate_pointer_path` before using it as `chdir`, so a tampered `worktree.yml` cannot send the diagnosis agent outside the configured worktree root.
- **Schema-listed generators only.** `generated_by` is a published JSON contract, not the open custom-profile registry. `DiagnosisAgent` refuses custom execute profiles unless their name has been added to `Hive::Schemas::DIAGNOSTIC_GENERATORS` and both status schemas in the same change.
- **ADR-019 nonce-wrapped prompt.** Prompt content is wrapped in a unique nonce so a prompt-injection payload embedded in an escalation file or log tail cannot reframe the spawn. This is the load-bearing security invariant. See `#prompt_for` and `Hive::SecretPatterns` for redaction. The artifact body is also passed through `sanitize_control_bytes` before write so a hostile log tail echoed by the agent cannot inject ANSI escapes into operator terminals or downstream JSON.
- **Freshness gate.** Before `File.rename`-ing the artifact into place, `marker_signature` is re-computed from the current marker; if it differs from the one captured at spawn, `StaleMarker` is raised and no artifact is written. This prevents a long-running diagnose from clobbering a marker that has since changed (e.g., the operator already cleared the row).
- **Atomic write.** Artifact write uses `Tempfile.create` in the destination directory plus `File.rename`, so a crashed spawn cannot leave a half-written `diagnostics/red-status.md` whose frontmatter would pass the `marker_signature` check.

## Artifact contract

The on-disk file is plain Markdown with a YAML frontmatter block:

```markdown
---
generated_by: claude
marker_signature: <SHA256 hex of marker.name + sorted attrs joined by newline>
diagnosed_at: <ISO 8601 UTC timestamp>
---

# Red Status Diagnosis

<agent-produced body, secret-redacted and control-byte-sanitised>
```

`Hive::TaskAction#diagnostic_generated_by` parses the frontmatter and returns the `generated_by` value as the `Diagnostic.generated_by` field in JSON. The enum is closed in `Hive::Schemas::DIAGNOSTIC_GENERATORS` (`local`, `claude`, `codex`, `pi`); extending it requires updating that constant and the enum in both `schemas/hive-status.v2.json` and `schemas/hive-status-diagnose.v1.json` in the same PR. Registering a custom `AgentProfile` alone is not enough.

## Consumers

| File | Use |
|------|-----|
| `lib/hive/commands/status.rb` | `diagnose_call` invokes `DiagnosisAgent.run!` when `--write` is passed and emits the resulting path under the `hive-status-diagnose` schema's `SuccessPayload.path`. |
| `lib/hive/tui/bubble_model.rb` | `refresh_red_status_diagnosis` shells out to `hive status --diagnose <slug> --write --force` via `Hive::Tui::Subprocess.dispatch_background`; the spawn ultimately re-enters this module. Per-folder dedup via `@diagnosis_inflight` prevents duplicate budget burn from held-down `R` keys within a single TUI session. |
| `lib/hive/task_action.rb` | `#diagnostic` reads the artifact `red-status.md` and prefers its body over the local fallback when `marker_signature` matches the current marker (`fresh_diagnosis_artifact`). |

## Backlinks

- [[modules/task_action]] — consumer that prefers fresh artifacts written by this module
- [[modules/agent_profile]] — the AgentProfile this module spawns (execute-stage profile)
- [[modules/secret_patterns]] — redaction patterns applied to the agent body before write
- [[commands/status]] — `--diagnose --write` entry point
- [[commands/tui]] — TUI `R` keybinding entry point
- [[decisions]] ADR-019 (nonce-wrapped prompts), ADR-025 (required-and-nullable envelopes), ADR-027 (diagnose-then-act, automation outside the lock)
