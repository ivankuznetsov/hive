## Remove unused JobStore jobs-directory helper

- Removed the private `RefactorPatrol::JobStore#jobs_dir` helper, whose only
  caller was a reflective unit-test assertion left behind by the v3 storage
  rewrite.
- Runtime job paths and traversal continue through the descriptor-confined
  `JobStoreFiles` collaborator, with its focused storage tests unchanged.
