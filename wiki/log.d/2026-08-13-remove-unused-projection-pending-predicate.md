# Remove unused projection-pending predicate

- Removed `OccurrenceJournal#projection_pending?`, which had no production
  caller.
- Its lower-level enumerator was subsequently removed after the Patrol
  forwarding surface retired; recovery continues through the bounded
  `each_recovery_active` view.
