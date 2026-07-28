# Replace the OpenClaw creator smoke fake with candidate-bound proof

- Moved workflow-creator proof mechanics into packaging-owned collaborators
  for safe archive materialization, disposable project setup, native OpenClaw
  configuration, command auditing, process supervision, and evidence
  inspection.
- Bound the dynamic run command to the first real idempotent task slug and
  required the retry output, task metadata, audit row, and evidence to agree.
- Reduced the authenticated smoke to a thin adapter, added deterministic
  real-candidate coverage, and pinned the OpenClaw creator workflow's Actions,
  OpenClaw version/integrity, and OpenAI/OpenRouter credential routing. The
  workflow now computes SHA-512 SRI from the single packed tarball and installs
  those verified local bytes rather than resolving the registry twice.

**Pages:** [[testing]] [[gaps]]
