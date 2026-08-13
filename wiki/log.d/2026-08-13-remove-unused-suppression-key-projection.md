# Remove unused suppression-key projection

- Removed `Review::Suppression.read_active_keys`, which had no production
  caller.
- Retargeted checked-entry, operator-entry, and unreadable-document tests to
  `read_active_entries`, the query used by live suppression filtering.
