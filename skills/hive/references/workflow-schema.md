# Owner-authored workflow schema

Descriptors live at `<hive_state_path>/workflows/ID.yml`; referenced agent
instructions live below `<hive_state_path>/workflows/ID/`. Use the current
format only. Stage indices are array order and are not authored as keys.

Every stage declares a safe `name`, `kind`, and relative `state_file`.
Agent stages declare exactly one of `instruction` or `skill`. Omit agent/model
to inherit project choices. Ordinary transitions are sequential array edges.

A human stage is closed and non-executable:

```yaml
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

Each outcome declares exactly one of `complete: true` or `to: STAGE`.
Completing outcomes require an artifact. Returning outcomes cannot declare an
artifact. Outcome and target names must be safe and targets must exist in the
same descriptor. Human stages cannot declare agent, model, permissions,
instruction, skill, budgets, timeouts, reviewers, councils, workspaces,
handoffs, conditions, or executable commands.

Treat `hive workflow validate ID --json` as authoritative for normalized
stages, automatic edges, human outcomes, and instruction paths.
