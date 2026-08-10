# Workflow creator example: editorial approval

Request: “Create a three-stage editorial workflow that researches, drafts,
and requires approval before publishing.”

The accepted interpretation is exactly `research -> draft -> approval`. There
is no inferred publish stage and no external publication action. Research and
draft inherit the project agent/model and use ordinary local `yolo`
permissions. Approval is a durable human stage.

```yaml
id: editorial
stages:
  - name: research
    kind: agent
    state_file: research.md
    instruction: editorial/research.md
    permissions: yolo
  - name: draft
    kind: agent
    state_file: draft.md
    instruction: editorial/draft.md
    permissions: yolo
  - name: approval
    kind: human
    state_file: approval.md
    input: draft.md
    outcomes:
      approve:
        complete: true
        artifact: draft.md
      reject:
        to: draft
```

`approve` requires a non-empty `draft.md`, records it as publish-ready, and
completes from approval. “Publish-ready” is an artifact status, not authority
to publish. `reject` records the decision, returns the same task to `draft`,
and resets draft to `WAITING` so stale completion cannot re-advance it.

Required validation facts:

- stages: research, draft, approval;
- automatic edges: research to draft, draft to approval;
- human outcomes: approval.approve completes with draft.md;
  approval.reject returns to draft;
- no task for a creation-only request; and
- no publish stage, destination, command, or external side effect.
