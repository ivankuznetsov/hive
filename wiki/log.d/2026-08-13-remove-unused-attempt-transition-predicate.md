# Remove unused attempt transition predicate

- Removed `Attempts::Record#transition_allowed?`, which had no production
  caller.
- Kept record state/schema validation and the store lifecycle/CAS tests that
  enforce legal durable attempt transitions.
