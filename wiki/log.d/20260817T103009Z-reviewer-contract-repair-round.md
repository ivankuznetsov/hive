# Reviewer contract violations reach the repair round

`Stages::Artifacts.run_reviewer!` retries `MAX_REVIEWER_ATTEMPTS` times and
feeds the failure back through `repair_json`, but it rescued only
`RoleOutputError` — shape problems like malformed JSON or unexpected top-level
keys. The semantic verdict contract runs later, inside `store.append_attempt!`,
which the caller invokes *after* `run_reviewer!` has returned. `StoreError`
from that append therefore escaped the loop entirely and ended the stage at
`outcome_evidence_invalid`, an operator-owned terminal marker with no dispatch
command, so the daemon parked the task.

The reviewer got zero repair turns for a violation it could fix by shortening
one sentence, while a missing brace got two.

Observed on `webmail.sh:build-the-first-implementation-milestone-260816-6240`:
three of seven verdict reasons ran 1337-1590 bytes against
`Contract::MAX_STATEMENT_BYTES` of 1024. The reviewer prompt does ask for under
600 characters; the model simply overshot.

`Contract.verdicts!` is now a public validation-only entry point, called inside
the loop before the reviewer result is accepted, and the rescue widened to
`StoreError` (`RoleOutputError` is a subclass, so shape failures behave as
before). `append_attempt!` still validates — this adds a repair round, it does
not move the authority.

See [[modules/task_workspace]].
