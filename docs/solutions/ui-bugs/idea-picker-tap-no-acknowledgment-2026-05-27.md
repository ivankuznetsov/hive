---
title: Telegram /idea picker tap gave no acknowledgment (silent-on-success dispatch)
date: 2026-05-27
category: ui-bugs
module: hive/bot
problem_type: ui_bug
component: service_object
severity: medium
related_components:
  - tooling
symptoms:
  - "Tapping a project in the /idea picker produced no reply — the button looked dead"
  - "A second tap of the same project button replied \"That idea picker expired. Send /idea <text> again.\""
  - "The captured inbox idea produced no immediate signal — its ready_to_brainstorm notification is suppressed on daemon-on projects and only fires on a later poll tick when daemon-off"
root_cause: logic_error
resolution_type: code_fix
tags:
  - telegram-bot
  - idea-capture
  - supervisor
  - child-process
  - callback-handler
  - exit-code
  - notification-suppression
---

# Telegram /idea picker tap gave no acknowledgment (silent-on-success dispatch)

## Problem

Picking a project from the Telegram `/idea` picker dispatched `hive new` as a child process, but `Supervisor#child_completion_text` returned `nil` for every exit-0 child. A successful idea capture therefore produced no reply — the picker button looked dead.

## Symptoms

- After `/idea <text>`, tapping a project in the inline picker appeared to do nothing (no confirmation, no error).
- A confused second tap replied: `That idea picker expired. Send /idea <text> again.`
- The idea was actually captured into `1-inbox` the whole time — there was just no acknowledgment, and no *immediate* follow-up either: inbox tasks carry action `ready_to_brainstorm`, which `NotificationDispatcher#suppress_ready_action?` suppresses when the project daemon is **enabled** (the daemon dispatches the transition itself); when the daemon is off the alert fires, but only on a later dispatcher poll tick, never at tap time.

## What Didn't Work

No real dead ends — this was diagnosed first try by tracing the full causal chain. The trap is that the failure *looks* like a dispatch or token-expiry bug: the visible message is "idea picker expired", and the picker token is consumed on first tap (`@pending_ideas.delete(token)` at `lib/hive/bot/handlers/callback_handlers.rb:138-140`). It is actually a missing-ack bug.

Future readers: do **not** chase the token/expiry logic in `CallbackHandlers#idea_project`. The token consumption and the "expired" branch are correct. The first tap succeeds silently; the re-tap only *reveals* the silence. The bug lives in the reaper's silent-on-success path, not the picker.

## Solution

PR #226, `lib/hive/bot/supervisor.rb`.

Before:

```ruby
elsif child.exit_code == 0
  # Clean success — no message. Operators see this signal via the
  # next status row (or its absence). The "Command completed" ack
  # was operational chatter with no actionable content.
  nil
```

After:

```ruby
elsif child.exit_code == 0
  # Clean success — no message for most commands ... The lone
  # exception is `hive new`: idea capture is fire-and-forget with no
  # status row the operator is watching ...
  new_capture_text(child)
```

```ruby
# argv[0] is rewritten to the resolved hive binary by
# ChildSupervisor#normalize_hive_bin, so key on the verb at argv[1].
def new_capture_text(child)
  argv = Array(child.command_argv)
  return nil unless argv[1].to_s == "new"

  project = child.project || argv[2]
  suffix = project ? " in #{project}" : ""
  "Captured your idea#{suffix}. It's in the inbox — move it to 2-brainstorm to start."
end
```

Detection keys on `argv[1]`, **not** `argv[0]`: `ChildSupervisor#normalize_hive_bin` rewrites `argv[0]` to a resolved absolute binary path (e.g. `/usr/local/bin/hive`), so the literal `"hive"` is gone by the time the reaper sees it — but the verb (`"new"`) is stable at index 1. All other exit-0 commands still return `nil`.

## Why This Works

The root cause is two compounding gaps:

1. The dispatch path (`CallbackHandlers#idea_project` → `dispatch_then_reply` → `hive new`) was **silent on success**.
2. The resulting `1-inbox` state has **no immediate follow-up signal** — its `ready_to_brainstorm` action is suppressed entirely when the daemon is on, and when the daemon is off it only fires on a later poll tick (never at tap time); there is no status row the operator is watching for a freshly-captured idea.

Most commands are fine staying silent because their effect surfaces in the next status row or a downstream notification; `hive new` had neither, so the only correct fix is an explicit ack at the moment the result lands. `/approve` and `/done` share the silent-success shape but were deliberately left unchanged: they degrade gracefully — a re-tap hits `WRONG_STAGE` → "Already advanced by another device", and the stage advance emits a downstream notification.

## Prevention

- Tests added in `test/unit/bot/supervisor_test.rb`:
  - `test_child_completion_text_acknowledges_successful_idea_capture` — confirms the ack names the project.
  - `test_child_completion_text_acknowledges_capture_when_hive_bin_resolved` — locks in `argv[1]` detection against the resolved-binary-path regression.
  - `test_child_completion_text_stays_silent_for_non_new_success` — guards the silent default for all other commands.
- **General guard:** fire-and-forget dispatch that is silent on success needs an explicit acknowledgment whenever the result lands in a state that has no follow-up signal (no status row, no downstream notification, suppressed action).
- **How to spot other instances:** audit every `dispatch_then_reply` / `dispatch_commands` callback for commands whose success produces neither a status-row change the operator is watching nor a downstream push. Each such command needs its own confirmation in `child_completion_text`. Flag any new exit-0 branch that returns `nil` unconditionally and pair it with the question: "is there a follow-up signal for this command's result state?"

## Related Issues

- GitHub #96 — `feat(bot): notify on legacy_stage_dirs transition` (closed); adjacent bot-notification-completeness work.
- GitHub #91 — Bot lacks Refresh-diagnosis equivalent of TUI R keystroke (closed); adjacent bot-feedback work.
- `docs/solutions/architecture-patterns/daemon-plan-approval-policy-exception-2026-05-15.md` — thematic only: another "durable success produced no observable advance" surface, different mechanism.
