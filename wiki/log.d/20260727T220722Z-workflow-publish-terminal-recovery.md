## [2026-07-27T22:07:22Z] workflow publish — retain terminal lifecycle after branch cleanup

- Kept open publication PRs bound to their live exact branch, while allowing a
  merged or closed PR to reconcile after GitHub deletes its source branch.
  A surviving terminal branch still fails closed if it moved from the
  immutable PR head.
- Hardened retained publication Git state before clone or reuse: the object
  root must already satisfy the owner-private no-symlink contract, retained
  checkouts and `.git` directories must be real current-user directories, and
  checkout permissions are narrowed to `0700`.
- Added focused recovery tests for deleted terminal branches, missing open
  branches, moved surviving branches, linked object roots/checkouts, and
  non-private object roots.
