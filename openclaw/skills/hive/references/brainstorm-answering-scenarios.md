# Brainstorm answering scenarios

These transport-neutral transcripts make the policy in
`brainstorm-answering.md` concrete. They are regression cases, not permission
to replace current evidence with canned answers. In every case, the full
`hive status --json` snapshot supplies traversal order, `hive answer` inventory
supplies slot truth, and only the bound write form may persist final text.

The symbolic bindings `b1`, `b2`, and so on stand for opaque tokens returned by
the observed inventory. Never copy a token between tasks or reconstruct one
from the fields shown here.

## Guided and discovery transcripts

### S01 — Status-only inventory and preview

- **Input:** `What brainstorm input is waiting?`
- **Observed binding:** The original status snapshot orders
  `beta:beta-brainstorm-260810-bbbb` before
  `alpha:alpha-brainstorm-260810-aaaa`. The beta inventory reports four
  unanswered slots out of five and returns `b1` for document-order `Q1/5`.
  Failed `broken-load`, `missing`, and `plain` project rows respectively carry
  `project_load_failed`, `missing_project_path`, and `not_initialised`; all
  remain unknown.
- **Expected message:** List beta before alpha, report each inventory's actual
  unanswered count, mark every failed project unknown, optionally preview beta
  `Q1/5`, offer Guided or YOLO, and state that no answer was written.
- **Mutation count:** `0`.
- **Final slot state:** Every `brainstorm.md` byte and task stage is unchanged;
  read-only inventory creates no task lock.

This case deliberately gives status stale aggregate counts (`0` for beta and
`9` for alpha). The response uses the inventories' `4` and `1`, not those
aggregates.

### S02 — Ambiguous answering request selects Guided presentation

- **Input:** `Help me answer the next question.`
- **Observed binding:** Fresh discovery selects the first actionable slot and
  retains its project, task, `Qordinal/total`, fingerprint, and opaque binding.
- **Expected message:** State that Guided is active, show exactly one question,
  context, recommendation or honest ambiguity, and the `approve`, replacement,
  `skip`, and `later` reply contract.
- **Mutation count:** `0`.
- **Final slot state:** The presented slot remains unanswered while Hive waits
  for a user-approved answer.

Mode comparison, recommendation preview, bare `continue`, and a later status
request have the same no-write boundary. Only an explicit `YOLO` or equivalent
current request enters automatic scanning.

### S03 — Guided approval writes one bound recommendation

- **Input:** `approve`.
- **Observed binding:** The immediately preceding Guided turn presented one
  recommendation with binding `b1`. A newer status snapshot happens to put
  another task first.
- **Expected message:** Submit the displayed recommendation through stdin with
  `b1`, acknowledge the command's `written` outcome, refresh status, and at
  most preview one next question. Do not switch to the newly first task before
  applying `b1`.
- **Mutation count:** `1`.
- **Final slot state:** Only the slot bound by `b1` contains the displayed
  recommendation.

### S04 — Guided replacement is literal text

- **Input:** `Use $(touch never) and \`echo never\`.` followed by a second
  line.
- **Observed binding:** One recoverable Guided binding `b1`.
- **Expected message:** Pass both lines through stdin, acknowledge exactly the
  recorded text, and do not interpret metacharacters as commands.
- **Mutation count:** `1`.
- **Final slot state:** The bound answer contains the replacement literally,
  subject only to the command's documented newline normalization. No side file
  or command effect exists.

### S05 — Guided skip, later, and resume

- **Input:** First `skip` or `later`; in a later answering turn the user gives
  final literal answer text.
- **Observed binding:** The first turn has `b1`. Resume re-runs discovery and
  obtains fresh binding `b2` for the still-unanswered slot.
- **Expected message:** The pause turn states that nothing changed. A status
  request after the pause remains read-only. The later explicit answering turn
  may write with `b2` and acknowledge one outcome.
- **Mutation count:** `0` for the pause; `1` only for the later literal answer.
- **Final slot state:** Empty after the pause; filled only after the explicit
  resumed answer.

### S06 — Repeated identical approval is idempotent

- **Input:** The same approved answer is retried with `b1`.
- **Observed binding:** `b1` already identifies a slot containing canonically
  identical text.
- **Expected message:** Report `idempotent` and say the answer was already
  recorded. Do not count or describe a new write.
- **Mutation count:** `0` on the retry.
- **Final slot state:** The first answer remains byte-for-byte unchanged.

If the retry supplies different text, the expected outcome is `conflict`, also
with zero mutations and no overwrite.

### S07 — Stale Guided reply fails closed

- **Input:** `approve` or replacement text after the task moved, its generation
  changed, or its question wording changed.
- **Observed binding:** The prior turn has `b1`, but under-lock revalidation no
  longer finds its exact identity and question state.
- **Expected message:** Report `stale`, discard `b1`, and offer fresh discovery.
  Do not redirect the answer to a similar or newly first slot.
- **Mutation count:** `0`.
- **Final slot state:** No current task receives the stale answer, and a moved
  task's old folder is not recreated.

## YOLO transcripts

### S08 — YOLO with only ambiguous questions writes nothing

- **Input:** `YOLO`.
- **Observed binding:** Every unanswered slot requires product preference or
  has materially conflicting evidence; inventories themselves remain valid.
- **Expected message:** Continue evaluating the whole preserved waiting set,
  then report the exact scanned count, `written: 0`, and the escalated count.
  Present only the first ambiguity.
- **Mutation count:** `0`.
- **Final slot state:** Every ambiguous slot remains unanswered.

Explicit YOLO changes scanning authority, not the evidence threshold.

### S09 — YOLO writes safe later slots past ambiguity

- **Input:** `Answer everything you can justify.`
- **Observed binding:** The original snapshot orders beta before alpha. Beta has
  an ambiguous Round 1 `Q1`, one settled slot, an evidence-backed later Round 2
  `Q1`, an evidence-backed literal-surface question, and another ambiguous
  preference. Alpha has one evidence-backed Guided-default question. Fresh
  inventories return a new bound token before each write.
- **Expected message:** Scan all five unanswered slots, leave both preferences
  empty, write beta document ordinals 3 and 4, then alpha ordinal 1 even if a
  post-write status snapshot reorders alpha first. Briefly acknowledge each
  write and summarize `scanned: 5`, `written: 3`, `escalated: 2`.
- **Mutation count:** `3`.
- **Final slot state:** The earlier Round 1 `Q1` stays empty while the later
  Round 2 `Q1` is answered; the second ambiguous preference also stays empty.

This is the cross-round number-reset regression: source question number alone
must never route the later answer into the earlier slot.

### S10 — YOLO escalation pauses and continues one at a time

- **Input:** While the first ambiguity is presented, `later`; afterward,
  explicit `continue`.
- **Observed binding:** Only the first escalated slot is presented and bound
  before the pause. The second is still queued as an ambiguity, not presented
  as another answer target.
- **Expected message:** `later` performs no write and pauses. `continue`
  refreshes and presents the next single ambiguity; it is never submitted as
  answer text. Wait again for literal user direction.
- **Mutation count:** `0` for both control replies.
- **Final slot state:** Both ambiguous slots remain unanswered until each gets
  its own explicit answer.

## Persistence and lifecycle fixtures

The executable regression harness pairs the transcripts with real temporary
coding task folders and `Hive::Commands::Answer`. These cases assert filesystem
postconditions rather than trying to prove atomic behavior from skill prose:

| Fixture | Binding change | Expected outcome and final state |
|---|---|---|
| Partial multi-round | Status count disagrees with physical slots | Inventory preserves document order, settled answers, and the true first empty slot. |
| Missing `A` header | Bound question has no answer header | `written`; insert the matching header inside that question block and leave the next slot empty. |
| Unique renumber | `Q1/A1` becomes `Q9/A9`, wording unchanged | `written` with unique relocation to the unanswered fingerprint match. |
| Duplicate fingerprint | Two current questions have the same normalized text | `ambiguous`; no byte changes. |
| Moved stage | Task moves from `2-brainstorm` to `3-plan` | `stale`; no write and no recreated source folder. |
| Changed generation | Task metadata/input incarnation changes | `stale`; no answer changes. |
| Already answered | Same or different retry text | `idempotent` for identical text, `conflict` for different text, never overwrite. |
| Same number across rounds | Earlier and later rounds both use source `Q1` | The bound document ordinal writes only the later slot. |

Incomplete project rows (`missing_project_path`, `not_initialised`, or
`project_load_failed`) remain unknown and never enter this mutation matrix.

### S11 — Final slot proves completion without dispatch

- **Input:** Final literal answer text for the one remaining bound slot.
- **Observed binding:** A fresh inventory returns `b1` for the last unanswered
  slot. The write receipt reports zero unanswered slots.
- **Expected message:** Refresh status and inventory, report completion only
  after `unanswered_count: 0` and `complete: true`, and make no claim that this
  answer itself advanced a stage.
- **Mutation count:** `1`.
- **Final slot state:** Every slot is answered, while the task folder still
  exists at `2-brainstorm`. Normal Hive or daemon policy alone may advance it.

## Sanitized cross-transport regression

### S12 — 2026-07-25 evidence-backed answers plus one escalation

- **Input:** `Please answer every remaining product question you can support,
  and ask me about the rest.`
- **Observed binding:** A fresh status snapshot, task identity, physical slot
  ordinals, fingerprints, and opaque per-write bindings only. All account,
  sender, conversation, and delivery metadata has been removed.
- **Expected message:** Apply the same explicit-YOLO evidence threshold on
  OpenClaw, Claude, Codex, and Pi; acknowledge two safe writes, summarize the
  scan, and present one unresolved product choice.
- **Mutation count:** `2`.
- **Final slot state:** Evidence-backed answers are present and the unresolved
  preference remains empty.

This case preserves only the decision pattern needed for regression. It does
not grant transport-specific behavior, external publication authority, or
permission to retain private conversation metadata.
