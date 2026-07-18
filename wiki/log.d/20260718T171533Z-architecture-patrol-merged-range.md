## Fix architecture-patrol merged-PR range filtering

- Changed GitHub merged-PR catch-up to express a bounded scan as one exact ISO
  timestamp range qualifier instead of two independent `merged:` qualifiers.
- Added regression assertions that the GraphQL search contains exactly one
  `merged:` qualifier, preserves both frozen timestamps, and retains the
  lower-only and upper-only query forms.
- Documented the single-range invariant for merge-intake pagination and result
  count convergence.
