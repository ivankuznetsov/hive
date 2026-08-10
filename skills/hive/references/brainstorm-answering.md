# Brainstorm answering

Use this policy when a conversation invokes the canonical Hive skill to find,
recommend, or persist answers for coding tasks waiting at `2-brainstorm`. It is
transport-neutral: the same behavior applies through OpenClaw, Claude, Codex,
and Pi when this canonical skill is invoked.

Load `brainstorm-answering-scenarios.md` when validating this behavior or when
an exact transcript example would clarify a state transition. Its examples
exercise this policy; they never replace current evidence or fresh bindings.

Native Telegram `/answer` and Hive web forms remain literal-answer surfaces.
They write the operator's text and do not acquire this recommendation layer.
Do not add a transport sidecar or treat conversation memory as answer truth;
`brainstorm.md`, the current task identity, and the supported `hive answer`
command remain authoritative.

## Modes and mutation boundary

Guided is the default. It presents one bound unanswered question, relevant
context, and an evidence-grounded recommendation, then waits for the user to
approve or replace that answer. It may resolve at most one user-approved answer
per turn.

YOLO requires explicit opt-in for the current answering run. Accept clear
instructions such as `YOLO`, "answer everything you can", or an equally direct
request to persist all safely justified answers. Do not infer YOLO from
`continue`, a status question, a request to preview recommendations, or an
earlier unrelated conversation. `skip` or `later` pauses the same bound run;
within that context, explicit `continue` may resume the same paused YOLO run.
The opt-in expires only when the run is exhausted or abandoned, or when its
binding context is lost; a later run then needs another explicit opt-in.

Status-only discovery is read-only. A request to list what is waiting, count
questions, show the next question, or compare modes may inspect status and
answer inventories and may preview one recommendation, but it never invokes the
write form. An ambiguous answering request defaults to Guided presentation,
not mutation. A request that already supplies literal answer text may write it
only after the exact task and slot are uniquely bound during that turn.

The recommendation layer chooses text; it does not implement persistence.
Every mutation goes through the supported literal `hive answer` command with a
fresh opaque binding, fixed argv, and the answer provided through stdin. Never
interpolate an answer into shell text and never edit `brainstorm.md` directly.

## Discover the waiting set

1. Take one fresh full snapshot with `hive status --json`. This full
   `hive-status` graph, rather than operational-status prose, defines the
   traversal set and order for this pass.
2. Require a successful top-level document. Preserve the returned project and task order
   exactly; do not re-sort by age, slug, project, or inferred priority.
3. Treat every project row carrying `missing_project_path`, `not_initialised`,
   or `project_load_failed` as unknown. Its empty or incomplete task list is not
   proof that nothing is waiting. Report the project error and perform no
   answering mutation for that project. Missing, malformed, or failed status
   documents make the affected scope unknown and read-only.
4. Consider typed coding rows at `2-brainstorm` that are waiting for input.
   Status fields identify candidates and preserve order; do not use status
   prose as data and do not treat the aggregate `unanswered_questions` field as
   slot truth.
5. For each candidate in that preserved order, run:

   ```text
   hive answer TASK --project PROJECT --json
   ```

   Require a successful `hive-answer` inventory. Its physical-order `slots`,
   `slot_count`, `unanswered_count`, answers, fingerprints, and bindings are the
   current `brainstorm.md` slot truth. If inventory fails or identity is
   ambiguous, mark that task unknown and do not mutate it.

Build a compact inventory from those exact results. Identify tasks by
`project:slug`, report `unanswered_count/slot_count`, and preserve snapshot
order. A status-only response may preview the first actionable unanswered slot
and offer Guided or YOLO; it must say that no answer was written.

Display a slot as `Q{ordinal}/{slot_count}` using the task-local document
ordinal, never the source `Q` number alone. Source question numbers restart
between rounds. Include the current unanswered count and round/source number
only as secondary context when useful.

## Recommendation authority

Choose or recommend an answer from the following precedence, highest first:

1. Current user instructions and settled answers, including explicit product
   choices already recorded in this brainstorm.
2. Hive safety contracts and verified repository facts, using current source,
   tests, configuration, or supported command output rather than remembered
   assumptions.
3. Task material and authoritative dossiers, including the task request,
   adjacent research, accepted project documentation, and scoped evidence.
4. Agent inference, clearly identified and constrained by the higher sources.

Never override a higher source with a lower one. If sources at the same or
higher authority materially disagree, or a proposed answer would invent user
preference, permission, release authority, destructive scope, credentials, or
external publication intent, treat the unresolved conflict as ambiguous and
fail closed without a write.

An answer is evidence-backed only when this hierarchy supports one exact,
defensible text and no material contrary evidence remains. Several plausible
designs, missing product preference, unverifiable repository behavior, or a
meaningful safety trade-off are ambiguity, not permission to pick the agent's
favorite. Existing settled answers remain durable user intent unless the user
explicitly replaces them through an appropriate current slot.

## Guided flow

1. From the preserved waiting set, choose the first unanswered slot in the
   first actionable task. Keep the inventory's project, task identity, slot
   metadata, fingerprint, and opaque binding together.
2. Present `project:slug`, `Q{ordinal}/{slot_count}`, unanswered count, exact
   question text, concise relevant context, the recommended answer, and a brief
   evidence rationale. If evidence supports options but not one answer, present
   the ambiguity instead of pretending to recommend.
3. Explain the reply contract: `approve` accepts the displayed recommendation;
   replacement text uses the user's text literally; `skip` or `later` performs
   no write and pauses this flow.
4. While waiting, retain its opaque binding even if a later status snapshot
   reorders tasks. Do not silently switch the presented question to a newly
   first task. The write command will reject a moved, edited, replaced, or
   otherwise stale slot.
5. On `approve`, write exactly the displayed recommendation. On replacement
   text, write exactly that text. Invoke the fixed command argv below and pass
   the answer through stdin:

   ```text
   hive answer TASK --project PROJECT --binding TOKEN --json
   ```

6. A bare `approve` or `continue`, or unbound replacement text, is read-only
   when the conversation no longer has one recoverable presented binding.
   Refresh discovery and present the question again; never guess which slot the
   reply meant.
7. After the closed outcome, give its semantic acknowledgement and refresh
   lifecycle state as described below. Guided may then preview the next bound
   question, but it must wait for another user reply before another write.

`skip` and `later` do not answer a different slot in the same turn. Preserve no
authority to mutate merely because the user later asks for status; resume with
fresh discovery and an explicit answering reply.

## YOLO flow

Start from one fresh full-status waiting set. Scan every unanswered slot in the
preserved task and physical document order. Count a slot as scanned when its
current question and evidence have been evaluated.

For each slot:

1. Apply the recommendation hierarchy and evidence threshold. If one exact
   answer is justified, it is eligible. If not, record it for later escalation
   and continue scanning after an ambiguous slot; ambiguity in an earlier round
   must not prevent a safe later-round write.
2. Take a fresh inventory before every write. Re-find the same still-unanswered
   slot by its bound identity/fingerprint in that inventory and use the new
   binding it returns. If it moved, changed, disappeared, became multiply
   matched, or was answered differently, do not write it.
3. Pass the chosen literal text through stdin to the bound `hive answer`
   command. Parse its closed outcome, acknowledge it briefly, then take a fresh
   `hive status --json` snapshot after every write before considering another
   mutation. Do not carry a status traversal row forward as write authority.
4. The original full-status order remains the traversal authority for this
   pass. A fresh status may validate or remove an original task, but it never
   reorders the remaining tasks or adds a newly appeared task to the pass. Do
   not retry a closed refusal by bypassing the binding or by editing the file.

At the end of the automatic pass, summarize scanned, written, and escalated
counts explicitly, plus any idempotent, conflict, stale, ambiguous, or lock-busy
outcomes that explain the totals. Written counts only new `written` outcomes;
an idempotent outcome confirms existing truth but is not a new write.

Then escalate one ambiguous question at a time. Refresh its task inventory,
present its current bound context and the missing choice, and wait for literal
user direction. After one escalated answer is persisted or the user says
`skip`/`later`, pause. Do not present or write the next ambiguity until an
explicit `continue`; that word resumes scanning or escalation but is never an
answer to a question by itself.

## Closed outcomes and acknowledgement

The write form returns one of: written, idempotent, stale, ambiguous, conflict, or lock_busy.
Treat the JSON fields, not prose or exit success alone, as the authority:

- `written`: one slot received the literal answer. Repeat the command's brief
  semantic acknowledgement.
- `idempotent`: that slot already contains the identical answer. Acknowledge it
  as already recorded; do not claim a new write.
- `stale`: task identity, generation, stage, question, or binding changed.
  Discard the pending binding and refresh. A task that normally advanced after
  a prior completed answer is progression, not permission to write its old
  path.
- `ambiguous`: multiple current slots match. Nothing changed. Present fresh
  context or escalate; never select one by position.
- `conflict`: the slot already has a different answer. Nothing changed and the
  current `brainstorm.md` answer remains truth. Report the conflict rather than
  overwriting it.
- `lock_busy`: another Hive operation owns the task lock. Nothing changed.
  Continue only with unrelated slots; retry this one later from a fresh
  inventory, without a polling loop.

Malformed binding/answer, wrong-stage, missing-task, configuration, and internal
error envelopes are also no-write results. Keep acknowledgements concise but
semantic: identify the task and `Q{ordinal}/{slot_count}` when current inventory
still proves them, and state whether text was recorded, already present, or not
changed.

## Completion and lifecycle

Take a fresh `hive status --json` snapshot after every write attempt. Use a fresh answer
inventory when the task remains at `2-brainstorm`; only its
`unanswered_count: 0` and `complete: true` prove that every required slot is
answered. Report completion only after that proof. If status shows the task
already moved, report the observed normal progression and do not reuse its old
binding.

Never dispatch a stage from this answer flow. Do not invoke `hive brainstorm`,
`hive act`, a suggested command, or a folder move merely because the last slot
was answered. Normal Hive/daemon completion gating remains the sole authority
to advance the completed brainstorm.
