# Restore OpenCode shell parity in benchmark cells

- Audited the completed Ox Alpha high artifacts and found that OpenCode had
  only read/write/edit permissions while Pi could run repository diagnostics
  and tests inside the same disposable benchmark container.
- Added the explicit scoped `Bash(*)` grant to the packaged benchmark runtime.
  The exact-base checkout and provider-only network remain the security
  boundary; the permission makes the harness comparison measure the model
  rather than an accidental tool handicap.
- Marked the earlier OpenCode high score as superseded pending a clean
  six-cell rerun and added focused packaged-runtime coverage for the grant.
