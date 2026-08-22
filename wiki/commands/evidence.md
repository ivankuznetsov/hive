---
title: hive evidence
type: command
source: lib/hive/commands/evidence.rb, lib/hive/artifacts/browser_gateway.rb, lib/hive/artifacts/terminal_recorder.rb, lib/hive/artifacts/managed_project_server.rb
created: 2026-08-14
updated: 2026-08-22
tags: [command, artifacts, evidence, recovery]
---

**TLDR**: `hive evidence recover` is the stale-safe operator acknowledgement
for a semantically blocked package. `hive evidence terminal` and
`hive evidence browser` are the internal, controller-scoped capture boundaries
given to an outcome-evidence producer. `hive evidence server` is the internal
boundary that lets a Pi producer request one attempt-owned project application
without receiving shell or process-lifecycle authority.

## Usage

```sh
hive evidence recover TARGET \
  --generation <sha256> \
  --recovery-digest <sha256>
```

Inside a producer context, Hive also issues:

```sh
hive evidence terminal NAME --json -- COMMAND...
hive evidence browser snapshot -i
hive evidence browser screenshot NAME.png --full
hive evidence browser record start NAME.webm
hive evidence browser record stop
hive evidence server bin/rails --json -- server -b 127.0.0.1 -p PORT
```

This form requires controller-issued task/source/write roots and has no
completion authority by itself.
It launches one argv command directly, records an asciinema v2-compatible
`NAME.cast`, writes a bounded ANSI-free `NAME.txt`, and returns
controller-observed paths, byte sizes, and SHA-256 digests. It does not invoke a
shell, asciinema, VHS, or a terminal-GIF encoder. A nonzero child exit is
recorded in both the receipt and text rather than erasing the evidence. On Linux,
the recorder runs inside Hive's child-subreaper custody boundary; timeout,
overflow, success, and failure all terminate and reap the complete descendant
tree, and any detached child makes the capture invalid.
The target command also runs inside the credential-free project sandbox. The
committed worktree is read-only except for existing `log/`, `storage/`, and
`tmp/` runtime directories, so a proof command cannot mutate the source it is
supposed to attest. The transcript still displays the requested command, not
the controller's bubblewrap prefix.

The internal capture forms send bounded JSON through a controller-owned filesystem
mailbox; the producer does not execute the PTY recorder or browser gateway.
The browser form therefore never receives agent-browser's raw socket. Hive
fixes the session, managed Chrome executable, one `.invalid` origin, and
loopback proxy. The gateway admits navigation, snapshots,
interaction, safe basename screenshots, and WebM recording; rejects other
origins, path syntax, filesystem-export commands, and socket/session overrides;
and exclusively publishes media from a controller-private staging directory into
the attempt root. Hive records a path/size/digest/media-type receipt for every
controller-produced terminal or browser representation and rechecks it before
custody transfer. Browser commands have no completion authority by themselves.

The server form is available only through the same controller-issued mailbox.
Hive requires an executable regular repository file, rejects symlinks and
source-root escapes, assigns the exact loopback port, and launches the command
in a credential-free bubblewrap sandbox. Source is read-only except for existing
`log/`, `storage/`, and `tmp/` runtime directories. Hive accepts readiness only
after the issued HTTP root returns a status below 500, retains at most 64 KiB of
startup diagnostics, and terminates the exact process group when the attempt
ends. A second server request in one attempt is rejected.

Use `--project NAME` or `--stage 7-artifacts` to disambiguate a bare slug. The
command also accepts the ordinary explicit `PROJECT:SLUG` target. `--json`
emits one machine-readable result.

Do not invent either digest. Copy the complete command from the task's current
status diagnostic, Hivebox blocker panel, or `hive run` recovery output after
reviewing the independent reviewer reasons.

## Guards and effects

The command acquires the task lock and requires all of these observations to
still agree:

1. the task marker is the semantic outcome-evidence `ERROR` observed by the
   operator;
2. its `generation` and `recovery_digest` equal the supplied values;
3. the strict `outcome-evidence/current.json` pointer is still blocked; and
4. the immutable requirement names the current durable task generation.

On success it advances `<task>/outcome-evidence/recovery.json` by one epoch and
rewrites the marker as `ERROR reason=outcome_evidence_recovery_ready`, carrying
the exact generation, digest, and new epoch. It preserves every requirement,
attempt, retained proof, rationale, and the blocked `current.json`. Repeating
the same exact recovery is idempotent; a superseded generation/digest or
concurrent package change fails closed.

Text output names the new epoch and the preserved generation. JSON output is:

```json
{
  "status": "recovery_ready",
  "task": "example-260814-abcd",
  "blocked_generation": "<sha256>",
  "recovery_epoch": 1
}
```

Recovery deliberately stops before dispatch. Refresh
`hive status --operational --json`, obtain its fresh guarded
`workflow.retry` action/token, and invoke that normal action boundary. The new
artifacts run opens a distinct outcome-evidence generation because the recovery
epoch is part of generation identity.

## Backlinks

- [[stages/artifacts]] · [[state-model]]
- [[commands/status]] · [[commands/run]] · [[commands/web]]
