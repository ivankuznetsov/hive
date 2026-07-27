# Workflow creator testing

Validate the descriptor with Hive before reporting success:

```bash
hive workflow validate ID --json
```

Check `valid`, origin, descriptor path, ordered stages/kinds, instruction
paths, automatic edges, and human outcomes. Validation must not change the
project tree, hive/state commit, tasks, registry, services, or timers.

For a human checkpoint, exercise both outcomes in a disposable task: completing
requires a non-empty artifact; returning records the decision, moves to the
declared stage, and leaves it waiting. Verify no agent dispatch occurs while a
human stage waits.

For an explicitly requested task, repeat the same idempotency key after the
task moves stages. The response must return one slug with `created: false`.
Reuse with different input/workflow must fail and leave one task. Finish with a
fresh operational status snapshot; hermetic validation is primary and live
agent proof is an additional, credential-gated attestation.
