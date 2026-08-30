---
title: 2-brainstorm stage
type: stage
source: lib/hive/stages/brainstorm.rb, lib/hive/brainstorm_suggestions/, lib/hive/daemon/brainstorm_suggestion_scheduler.rb, lib/hive/claude_launcher.rb, lib/hive/attempts/dispatcher.rb, lib/hive/tmux_runner.rb, templates/{brainstorm,brainstorm_suggestion}_prompt.md.erb
created: 2026-04-25
updated: 2026-08-30
tags: [stage, brainstorm, qa, tmux, suggestions, advisory, sandbox]
---

**TLDR**: Round-by-round Q&A. Agent reads `idea.md`, writes `brainstorm.md` with `## Round N` questions and a `<!-- WAITING -->` marker. User answers inline. Only after those questions are published, the daemon may generate one repository-aware advisory suggestion for each unanswered slot; suggestions never count as answers or block manual input. Re-running the stage parses answers and either appends `## Round N+1` or finalises with `## Requirements` and `<!-- COMPLETE -->`. Process exit and attempt receipts are not completion evidence by themselves: WAITING must contain a numbered Round, COMPLETE must contain non-empty Requirements, and a failed spawn cannot reuse an unchanged stale artifact. When the resolved `brainstorm.agent` is Claude, launch shape comes from project-global `claude.mode`: `tmux` runs Claude inside a managed attachable tmux session via `Hive::ClaudeLauncher`, while `headless` uses the normal non-interactive profile path. Legacy `brainstorm.runtime` is still read only when `claude.mode` is absent, and `hive doctor` advises migrating it.

## Setup

- **State file**: `brainstorm.md` (touched empty if absent so the marker write has a target).
- **Prompt**: `templates/brainstorm_prompt.md.erb`, rendered with `project_name`, `task_folder`, `idea_text`. Idea text is wrapped in `<user_supplied content_type="idea_text">…</user_supplied>` per the prompt-injection boundary policy.
- **Agent invocation**: `cwd = task.folder`, `--add-dir <task.folder>`, `log_label = "brainstorm"`. For `claude.mode: tmux`, `Hive::ClaudeLauncher` starts Claude through `interactive_claude_wrapper.sh`, unsets API-key env vars, maps `claude.permission_mode` (default `bypassPermissions`) to the same flags the headless path uses (`bypassPermissions` → `--dangerously-skip-permissions`, otherwise `--permission-mode <mode>`) plus `--allowedTools Read,Write,Edit,LS`, waits for the TUI prompt, and then asks `Hive::TmuxRunner` to paste the rendered prompt and submit only after the pane tail has settled.
- **Tmux readiness env vars**: `Hive::ClaudeLauncher` owns `HIVE_CLAUDE_TMUX_*` readiness settings. `SESSION_READY`, `PID_READY`, and `CLAUDE_READY` inherit `HIVE_CLAUDE_TMUX_READY_WAIT_TIMEOUT_SEC` when their specific env var is unset; `CLAUDE_READY` otherwise keeps a 120s bare default for slow Claude TUI startup. Legacy `HIVE_BRAINSTORM_TMUX_*` names remain fallback inputs during the migration window.
- **Claude TUI readiness predicates**: Trust, permission, banner, footer, and prompt-chrome strings are named constants in `Hive::ClaudeLauncher`, with observed coverage for Claude Code 2.1.133, the later line-end-caret footer shape, and Claude Code 2.1.179's separator/caret/separator/footer shape. `claude_ready_prompt?` accepts an idle `❯` caret at the start or end of the current input line, including Unicode separator spaces around the caret and the patrol-observed case where the captured pane tail has scrolled the `Claude Code` banner out but still shows `... PR #N ... for agents`. It classifies trust and permission prompts from the current prompt block instead of stale scrollback, rejects numbered menu options as non-ready, and only treats `⏵⏵` footer lines as prompt chrome when they carry the real bypass-permissions footer copy.
- **Tmux submit/session failures**: `Hive::TmuxRunner#send_prompt` loads and pastes the prompt through a tmux buffer, waits until the pane tail is identical across two consecutive captures (`PROMPT_SETTLE_STABLE_POLLS`) or the bounded `HIVE_TMUX_PROMPT_SETTLE_TIMEOUT_SEC` deadline passes, then sends one explicit Enter. `HIVE_TMUX_PROMPT_SUBMIT_DELAY_SEC` is the poll interval. This avoids the old large-paste race where Enter could fire while a multi-chunk prompt was still rendering and be swallowed by the input box. If tmux disappears before that Enter submit or a tmux command exceeds `HIVE_TMUX_COMMAND_TIMEOUT_SEC`, the typed tmux error propagates immediately. During marker polling, `Hive::ClaudeLauncher.wait_for_terminal_marker` also checks that the tmux session still exists while `brainstorm.md` is stuck on `AGENT_WORKING`; a disappeared session stamps `ERROR reason=tmux_session_terminated` instead of waiting for the full brainstorm timeout.
- **Tmux cleanup/orphan sweep**: cleanup is shared in `Hive::ClaudeLauncher`. After `/quit` and `kill_session`, the launcher sweeps leftover Claude processes by this task's `--add-dir <task.folder>` while skipping matched `tmux` commands and logging killed/skipped entries to `claude-tmux-orphan-sweep.log`. The skip is load-bearing because the tmux server can keep the first session's full argv and would otherwise match the task-specific sweep pattern.
- **Profile**: `Hive::Stages::Base.stage_profile(cfg, "brainstorm")` — reads `cfg.dig("brainstorm", "agent")` with `|| "claude"` fallback so legacy configs keep working. Spawn pins `status_mode: :state_file_marker` regardless of profile, because brainstorm's lifecycle contract is the WAITING/COMPLETE marker the agent writes to `brainstorm.md` — codex's profile default `:output_file_exists` would never satisfy that.
- **Budgets**: `cfg["budget_usd"]["brainstorm"]` (default 50), `cfg["timeout_sec"]["brainstorm"]` (default 1800). Bumped ~5× in plan 2026-05-04-001 — generous sanity caps for runaway agents, not cost targets.
- **Outcome reconciliation**: both headless and tmux launches snapshot
  `brainstorm.md` before spawning and consume the launch result afterward.
  `WAITING` is valid only with a numbered `## Round N` section; `COMPLETE` is
  valid only with a non-empty `## Requirements` section. A changed valid
  artifact wins over a trailing launch error (for example Claude emitting its
  structured max-budget result while unwinding), while an unchanged
  pre-existing artifact cannot hide a failed spawn. Missing/invalid output is
  stamped `ERROR reason=brainstorm_artifact_invalid` or
  `brainstorm_agent_failed`; an already-specific launcher/agent `ERROR`,
  including `budget_exhausted`, is retained.
- **Attempt replay repair**: the durable dispatcher does not treat a successful
  `2-brainstorm` receipt as replayable unless `brainstorm.md` currently passes
  the same structural validation. One legacy successful receipt without its
  artifact admits one repair attempt for that task generation, regardless of
  which request ID observes it. Once that repair terminalizes, its newest
  receipt is replayed instead of admitting an unbounded repair loop.

## Repository-aware answer suggestions

The ordinary brainstorm producer publishes a complete `WAITING` round first.
`Hive::Daemon::BrainstormSuggestionScheduler` then inventories every active
coding task at `2-brainstorm`, creates missing records for every unanswered
physical slot, and runs the advisory pass asynchronously. This reconciliation
also covers rounds created before the feature existed and a crash between
question publication and sidecar seeding. Generation never owns the answer
lock long enough to block an operator from typing or submitting an answer.

### Canonical state and freshness

`brainstorm-suggestions.json` at the active task root is the owner-private
canonical store. It contains only bounded lifecycle metadata and validated
candidate fields; raw repository context and rejected provider output are
never persisted. Missing records project as `loading`. The closed states are
`loading`, `fresh`, `stale`, `no_safe_suggestion`, `unavailable`, and `failed`.
Only a current, non-dismissed `fresh` record may expose `text`, `rationale`, or
provenance. Every other state projects null text and a bounded safe reason.

The `input_binding` covers the task incarnation/generation, brainstorm
generation, physical question identity and text, the exact selected manifest
(path, mode, content digest, source class, recipe name/version), and preceding
durably parsed operator answers. Repository-global `HEAD` is recorded only as
diagnostic metadata and is deliberately absent from freshness. A
`suggestion_binding` adds immutable attempt/candidate identity. Any binding
change hides the old candidate synchronously.

Capture runs outside the task lock. The scheduler briefly reacquires the exact
task lock to re-resolve stage/question/answer identity and compare-and-swap the
request or result, then re-observes the selected manifest after publication.
A late result cannot recreate a moved folder, overwrite a newer attempt, or
survive an operator answer.

### Eligible evidence and admission

The current `tracked-relevance` recipe (version 2) admits:

- the task request;
- bounded text files already in Git's index, read from the working tree so
  tracked staged/unstaged changes and deletions overlay committed blobs;
- bounded tracked `wiki/` files and relevant Markdown from a validated
  `.llm-wiki/config.json` `main_wiki_path`; and
- only durably parsed answers from preceding physical slots.

Untracked and ignored files are never enumerated. Relevant committed files are
selected deterministically, while tracked overlay paths are prioritized within
the same file/byte bounds. Conflicts, submodules, symlinks, special files,
descriptor races, oversized/binary/non-UTF-8 content, and secret-bearing
repository/wiki entries fail closed or are excluded. Task and settled-answer
text is redacted before use. Every excerpt is labelled as untrusted data.

The configured provider is launchable only when its profile proves the
`brainstorm_suggestion_data_only` capability. The shipped implementation
currently admits Claude only. Hive constructs a controller-owned Bubblewrap
runtime with no live project/task mount, an immutable `/bundle`, empty
settings/MCP configuration, disabled shell/network tools and slash commands,
and one schema-constrained stdout result channel. Unsupported profiles,
missing Bubblewrap, missing binaries, or unavailable isolation become
`unavailable` and are not launched. Runtime roots and directories are `0700`;
bundle/auth files are `0400`; every success, failure, timeout, TERM/KILL, and
spawn-error path removes the runtime. Daemon startup sweeps inactive
owner-matching runtime roots.

Admission accepts at most 1,000 UTF-8 characters and 12 lines of safe plain
text plus a short rationale. Fences, structural Markdown/HTML, controls,
prompt-control phrases, and secret patterns are rejected. Provider source
claims must be a nonempty subset of manifest classes, but Hive replaces them
with the controller-derived set actually present in the admitted manifest.
Weak, conflicting, sensitive, malformed, or unsafe output exposes no
actionable text.

### Regeneration and authority

The default `brainstorm.suggestions` block enables one configured worker,
allows three automatic attempts per input epoch, uses a five-second task-wide
coalescing window, waits at least 300 seconds between automatic retries, and
caps capture/provider work at 5/120 seconds. Backoff is jittered. There is one
active request per question/input binding and only one launch per task window;
an exhausted slot cannot consume that window. A new selected-input epoch resets
the budget, while unrelated commits and Hive marker commits do not.

`hive answer --json`, TUI, and Web consume the same sidecar projection. TUI
uses an exact `hive-suggestion:v1` comment envelope under the answer heading;
the parser, completeness check, first-pass prompt, and writer strip that whole
region before deciding whether a slot is answered. Web Approve/Undo and
Decline/Restore are browser-only presentation state. Retry/Restore/dismissal,
projection, persistence, and generation cannot write an answer, completion
marker, attempt, dispatch, or stage transition. Only the operator's saved TUI
adoption or Web **Send answers** submission reaches the existing answer
writer. Telegram and Guided/YOLO answer behavior is unchanged.

### Ownership cleanup and downgrade

Persisting an answer, removing a question, or leaving `2-brainstorm` cancels
matching workers and removes actionable sidecar/envelope state under the task
lock. Later stages, supporting artifacts, state commits, and archives must not
retain candidate text.

Before disabling, reverting, or downgrading this feature, run:

```bash
hive brainstorm-suggestion cleanup --json
```

With no target the command visits registered task stages under each exact task
lock, strips every reserved envelope, removes every sidecar, verifies parsed
operator answers are byte-for-byte unchanged, and emits an idempotent bounded
receipt. Proceed only when `safe_to_disable` is true. Configuration validation
refuses `brainstorm.suggestions.enabled: false` while any advisory artifact
remains, making this cleanup a mandatory compatibility fence for older parsers.

## Agent behaviour (per `templates/brainstorm_prompt.md.erb`)

1. If `brainstorm.md` is empty/missing, read `idea.md` and produce **Round 1** as a Q&A block:
   ```
   ## Round 1
   ### Q1. <question>
   ### A1.
   ### Q2. <question>
   ### A2.
   ```
   End with `<!-- WAITING -->`.
2. If `brainstorm.md` already has rounds, parse the most recent `## Round N`. If all answers are filled in, append `## Requirements` (actor / flow / acceptance examples) and end with `<!-- COMPLETE -->`. Otherwise append `## Round N+1` with follow-ups and end with `<!-- WAITING -->`.
3. Use `/ce-brainstorm` skill where available. Legacy `compound-engineering:ce-*` config values are normalized before rendering.

Agent must not modify any file other than `brainstorm.md` and must not run shell or network tools.

## Marker → commit action mapping (`Stages::Brainstorm.action_for`)

| Marker | Commit action |
|--------|---------------|
| `:waiting` | `round_waiting` |
| `:complete` | `complete` |
| `:error` | `error` |
| (other) | `<marker>.to_s` |

The runner returns `{commit: action, status: marker.name}` so `Commands::Run` writes a `hive: 2-brainstorm/<slug> <action>` commit on `hive/state`.

## Tests

- `test/integration/run_brainstorm_test.rb` exercises the prompt shape and marker transitions using the fake-claude fixture.
- `test/integration/run_brainstorm_tmux_test.rb` exercises the tmux launcher path.
- `test/unit/stages/brainstorm_runtime_test.rb` pins headless/tmux failure reconciliation, structural artifact validation, changed-artifact precedence, and stale-artifact rejection.
- `test/unit/attempts/dispatcher_test.rb` pins one repair admission for a successful Brainstorm receipt whose required artifact is absent.
- `test/unit/stages/brainstorm_tmux_sentinel_test.rb` exercises the live
  `ClaudeLauncher` readiness/sentinel helpers and pins the orphan-sweep
  invariant that matched Claude PIDs are terminated individually while the
  tmux server is skipped and logged.
- `test/unit/tmux_runner_test.rb` pins prompt-buffer cleanup, tmux command timeouts, and paste-settle behavior before the final Enter submit.

## Backlinks

- [[stages/inbox]] · [[stages/plan]]
- [[modules/agent]] · [[modules/markers]]
- [[state-model]]
