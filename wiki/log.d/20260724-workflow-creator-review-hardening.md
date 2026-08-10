## 2026-07-24 — Workflow creator review hardening

- Bound every human decision to the current `decision_id`, moved completion
  artifact verification under the task/commit locks, rejected marker-only
  artifacts, and separated completed-human status from archived tasks.
- Made human-stage entry reject symlinked state files and copy a stable,
  no-follow snapshot into the destination.
- Made `workflow validate` strictly read-only for authored, built-in, and
  managed workflows, including prepared managed journals, and gave malformed
  JSON invocations their command-specific schema.
- Made minimal-init collisions and failures machine-readable without replacing
  an unrelated same-basename registration.
- Serialized idempotent lookup, exclusive candidate creation, and commit so
  same-slug contenders cannot share or overwrite a task directory.
- Required the natural-language creator to commit its populated workflow graph
  after validation, and synchronized the canonical/OpenClaw guidance, public
  docs, wiki, schemas, and focused regressions.
