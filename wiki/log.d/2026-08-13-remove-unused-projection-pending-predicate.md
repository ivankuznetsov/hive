# Remove unused projection-pending predicate

- Removed `OccurrenceJournal#projection_pending?`, which had no production
  caller.
- Kept empty and pending-state coverage on `each_projection_pending`, the
  bounded enumerator used by patrol recovery.
