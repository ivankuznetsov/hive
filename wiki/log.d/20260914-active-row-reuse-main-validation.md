# Active-row reuse validated with numeric folder lookup

Rebased PR #1331 onto main after #1324 and #1327. Preserved the numeric registered-slug lookup and the current-format guide field. The same real generic terminal-workflow fixture classifies the active task twice on main and once with prepared-row reuse. This is classification-count evidence, not a fleet timing claim.

Shared the ordinary/active response envelope builder. Reconciled the archive-index test to request the internal index only for the indexed payload, preserving the ordinary payload exclusion and retention-boundary assertions.

Removed the redundant preparation-time attempt-store wrapper: both callers already own the scan store, and direct project payload ownership remains covered.
