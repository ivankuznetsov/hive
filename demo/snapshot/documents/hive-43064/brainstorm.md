## Round 1
### Q1. What is the smallest first release that would deliver real value: a full observe-through-activation loop, or a shadow-mode loop that stops after an evaluated activation proposal?
### A1. <!-- hive-answer:v1 -->
Keep the full observe-through-activation capability required by the task seed, including evaluated activation proposals, explicit human approval, smoke verification and rollback. Shadow mode may be an implementation milestone, but it is not a substitute for the stated acceptance criteria. This task does not authorize activating a candidate or publishing a release.
### Q2. Who is the primary human operator, and which authorities must remain separate among signal/thesis disposition, held-out evaluation ownership, activation approval, and rollback?
### A2. <!-- hive-answer:v1 -->
The primary operator is the owner of this local Hive installation. Reuse existing Patrol disposition ownership. Keep the proposer and execution worker separate from the held-out evaluator, with no access to hidden cases, rubrics or per-case results. Activation requires explicit human approval; the controller may perform the approved transition and the specified smoke-failure rollback. Do not invent separate human teams or a new approval service.
### Q3. Which repo-local artifacts may be evolution targets in the first release, and which instruction surfaces must explicitly remain out of scope even when Patrol finds relevant evidence?
### A3.

### Q4. What exact classes of Hive artifacts may supply learning signals, and what minimum redaction or derived-field boundary must apply before their content becomes durable evidence or llm-wiki knowledge?
### A4. <!-- hive-answer:v1 -->
Use only bounded, explicitly allowlisted Hive task artifacts relevant to the learning signal, with retained source identity and provenance. Exclude secrets, private conversations, raw unrelated transcripts, untracked or ignored files, and evaluator holdouts, exactly as the seed requires. Persist redacted derived evidence sufficient to reproduce the finding, not wholesale transcripts; uncertainty and contradictions remain explicit. Reuse the existing evidence admission and redaction mechanisms.
### Q5. When the same evidence plausibly indicates both a code defect and an instruction or workflow defect, what ownership and precedence rule should the target taxonomy apply, and may one signal produce more than one durable disposition?
### A5. <!-- hive-answer:v1 -->
Keep one active task in one workflow queue at a time. A confirmed code or architecture defect must be fixed at that layer, not hidden with a prompt workaround. Escalation transfers ownership to the linked successor and removes the source from its active Patrol queue; retain the relationship as evidence rather than running duplicate repairs. Instruction-only issues and knowledge-only updates use their own stated lanes. Do not create two active dispositions for the same repair.
### Q6. What minimum recurrence, independence, and evidence-quality bar should distinguish a skill-evolution thesis from a one-off finding or knowledge-only update?
### A6.

### Q7. What exact evaluation outcome should make a candidate approvable, including the required improvement over the active and fixed baselines, treatment of inconclusive results, and correctness or safety vetoes?
### A7.

### Q8. If a cycle loses its lease, exhausts the shared daily ceiling, or discovers that its pinned active version or default-branch basis has moved, which state should be resumable and which conditions should force a fresh immutable cycle?
### A8.

### Q9. Over what observation window, and by which measurable outcomes, should operators judge the first release successful beyond merely completing candidate evaluations?
### A9.

<!-- WAITING -->
