## 2026-11-08 — Fence recovery admission before binding attempts

- Manual retry validates accepted, existing-live and terminal-replay attempts
  against its full task/stage/generation/post-clear-progress binding before
  attachment or a durable recovery transition.
- The daemon's marker-recovery admission consumer uses the same fence and
  defers foreign attempts without binding the request or touching their work.
- Regression coverage exercises mismatched admission outcomes and real foreign
  existing-live admission through both consumers, then proves the same request
  can retry successfully after the foreign owner ends with one retry charge.
- Validation: 604 tests and 2,715 assertions pass across manual retry,
  attempt admission, recovery coordinator and daemon dispatcher tests.
