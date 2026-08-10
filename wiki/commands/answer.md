---
title: hive answer
type: command
source: lib/hive/commands/answer.rb, lib/hive/brainstorm_parser.rb, lib/hive/bot/brainstorm_answer_writer.rb, schemas/hive-answer.v1.json
created: 2026-08-10
updated: 2026-08-10
tags: [command, brainstorm, answers, bindings, concurrency, json, agents]
---

**TLDR**: `hive answer` is the transport-neutral literal boundary for coding
brainstorm answers. Without `--binding` it inventories the real
`brainstorm.md` slots in physical order without writing or publishing a task
lock. With a fresh opaque binding it reads one final answer from stdin,
revalidates task identity and the exact slot under a creation-disabled task
lock, and writes only on a closed safe outcome. It does not recommend an answer
and never dispatches or advances a stage.

## Invocation

```bash
hive answer TARGET --project PROJECT --json
printf '%s' "$ANSWER" |
  hive answer TARGET --project PROJECT --binding TOKEN --json
```

`TARGET` may be a task id, slug, or task path accepted by
`Hive::TaskResolver`. `--project` removes cross-project ambiguity and is
also checked against a supplied binding. The task must resolve to the coding
workflow at `2-brainstorm`; another workflow or stage is a wrong-stage error.

Use `--json` for agent callers. Text inventory reports only
`PROJECT/SLUG: UNANSWERED/TOTAL unanswered`; text mutation prints the same
brief semantic acknowledgement carried by the JSON result.

## Read-only inventory

An invocation without `--binding` reads `brainstorm.md` and emits
`hive-answer.v1` with:

- exact project, task id/slug/folder, `2-brainstorm` stage, and stable task
  generation;
- `slot_count`, `unanswered_count`, and `complete`;
- every question in physical document order, independent of source
  numbering, with a one-based task-local `ordinal`, round, original question
  number, text, answered state, answer, normalized fingerprint, and opaque
  binding.

The command observes identity a second time before returning. The inventory
path creates no lock and writes no file. It is therefore a preview, not a
lease: a caller must pass the returned binding to the write form, which
revalidates current state under the task lock.

`hive status --json` remains the authority for deterministic cross-project
and cross-task traversal order. Its aggregate `unanswered_questions` value can
lag a concurrent edit; this inventory's parsed slots are the answer truth for
the selected task.

## Bound literal write

The write form accepts the final literal answer only on stdin. It permits
multiline UTF-8 up to 64 KiB, rejects blank or invalid UTF-8 input, and never
interpolates answer text into a shell command. A binding is an opaque
Base64url token; callers must not decode, edit, or synthesize it.

Before mutation, Hive re-resolves the exact registered project and task. It
then acquires the existing task folder with `create: false` and rechecks:

1. project, task id, slug, canonical folder, coding workflow, and
   `2-brainstorm` stage;
2. the stable task generation, including task incarnation and input epoch;
3. the bound physical ordinal, round, source question number, and normalized
   question fingerprint.

If the exact ordinal changed, Hive relocates only when the normalized question
text has exactly one match. Multiple matches are ambiguous; zero matches are
stale. The shared writer preserves atomic replacement and repairs a missing
`### A<n>.` header only inside the selected question block.

An occupied slot is never overwritten. Repeating the identical canonical
answer is idempotent success; a different answer is a conflict. Moving the
task during the exchange, changing its generation or question, replacing its
folder, or removing it yields a no-write result and never recreates the old
folder.

## Closed write outcomes

Every syntactically valid write attempt returns `ok: true`,
`operation: "write"`, a semantic acknowledgement, and one closed outcome:

| Outcome | Meaning | Mutation |
|---|---|---|
| `written` | Exact slot or one unique relocated slot accepted the answer. | One atomic answer write. |
| `idempotent` | The selected slot already contains the same canonical answer. | None. |
| `stale` | Task identity, stage, generation, wording, or slot presence changed. | None. |
| `ambiguous` | More than one current question matches the bound fingerprint. | None. |
| `conflict` | The slot already contains a different answer. | None. |
| `lock_busy` | Another Hive operation owns the task lock. | None; retry from a fresh inventory. |

`reason` distinguishes exact match, unique relocation, identical/different
existing answers, changed/missing/multiply matched questions, missing/moved
tasks, identity/generation change, and lock contention. `written` is true
only for the first row. Where current task state is safely available, the
receipt also returns the resolved slot, remaining unanswered count, and
completion flag.

Malformed bindings and answers, ambiguous task lookup, invalid paths,
wrong-stage use, configuration failures, and unexpected internal failures use
the schema's `ok: false` error arm. A lock-free inventory whose identity
changes during its own two observations exits `75` as a stale operational
observation. Write-level stale and `lock_busy` states are closed exit-zero
receipts so callers can refresh deterministically.

## Lifecycle boundary

Completing the final slot changes only `brainstorm.md`. The command does not
set a completion marker, invoke `hive run`, move the folder, or authorize
`hive approve`. After every write attempt, take a fresh
`hive status --json` snapshot. Normal Hive/daemon policy remains responsible
for recognizing that no slots remain, resuming the brainstorm agent if
required, and advancing only through its existing completion gate.

The canonical Hive skill layers Guided recommendations and explicit YOLO
orchestration over this literal command. Native Telegram `/answer` and Hive
web forms remain literal-answer surfaces; they do not inherit recommendation
policy merely because the shared parser/writer boundary is used.

## Backlinks

- [[cli]]
- [[commands/status]]
- [[stages/brainstorm]]
- [[modules/bot]]
- [[testing]]
