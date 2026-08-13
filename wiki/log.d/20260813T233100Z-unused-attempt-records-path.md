## Remove unused attempt records path

- Removed the cleanup target after tracked callsite, reflective-dispatch,
  documentation, and available-history searches found no production consumer.
- Collected the six sibling attempt-subpath cleanups as dependencies and
  removed the shared `Paths.attempts_root` helper after its final caller was
  retired.
- Retained focused coverage for the live behavior surrounding the orphaned
  surface; untracked external Ruby callers remain the compatibility boundary.
