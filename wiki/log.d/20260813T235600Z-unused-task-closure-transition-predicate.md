## Remove unused task-closure predicate

- Removed the cleanup target after tracked callsite, reflective-dispatch,
  documentation, and available-history searches found no production consumer.
- Retained focused coverage for the live behavior surrounding the orphaned
  surface, including the CLI/bot-facing class confirmation boundary; untracked
  external Ruby callers remain the compatibility boundary.
