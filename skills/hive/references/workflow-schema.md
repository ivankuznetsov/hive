# Owner-authored workflow schema

Descriptors live at `<hive_state_path>/workflows/ID.yml`; referenced agent
instructions live below `<hive_state_path>/workflows/ID/`. Use the current
format only. Stage indices are array order and are not authored as keys.

Every stage declares a safe `name`, `kind`, and relative `state_file`.
Agent stages declare exactly one of `instruction` or `skill`. Omit agent/model
to inherit project choices. Ordinary transitions are sequential array edges.

A final direct agent stage may declare closed terminal semantics:

```yaml
- name: repair
  kind: agent
  state_file: repair-certificate.md
  deliverable: repair-certificate.md
  skill: /repair
  terminal_outcomes:
    complete: [verified, not-reproduced]
    blocked: [blocked]
```

Both lists are required, non-empty, unique, disjoint safe lowercase slugs of
at most 40 bytes. The stage must be the last agent stage and `deliverable` must
equal `state_file`. Do not combine this contract with `workspace` or `handoff`;
managed worktree reports use a separate controller-owned `Decision:` protocol.

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
stages, automatic edges, human outcomes, terminal outcomes, and instruction
paths. Confirm the returned final stage contains the exact complete and
blocked arrays you authored.
