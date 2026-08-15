## Remove unused attempt proof path

- Removed the cleanup target after tracked callsite, reflective-dispatch,
  documentation, and available-history searches found no production consumer.
- Retained focused coverage for the live behavior surrounding the orphaned
  surface; untracked external Ruby callers remain the compatibility boundary.
