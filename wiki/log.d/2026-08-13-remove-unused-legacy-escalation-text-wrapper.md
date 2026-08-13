# Remove unused legacy escalation text wrapper

- Removed the unused `Stages::Review.collect_legacy_checked_escalations`
  text-only wrapper.
- Kept legacy checked-escalation fallback and read-failure coverage on
  `collect_legacy_checked_escalations_with_count`, the result API used by the
  review pipeline.
