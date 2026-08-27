---
date: 2026-08-22
tags: [patrol, architecture-patrol, migration, admission, performance]
---

# Historical Patrol import reserves before materializing

- Changed the one-time Patrol importer so ordinary and Architecture Patrol
  sources both enter the shared `AdmissionStore`; import no longer creates or
  scans workflow task folders.
- Added pure source-adapter reservation builders so live publication and
  historical import share occurrence and snapshot identity without a temporary
  admission store.
- Preserved fail-closed duplicate ordinary-finding detection before any
  admission is written.
- Task creation remains owned by the admission scheduler after semantic
  selection and workflow-capacity checks, keeping status-scan task count
  bounded by admitted work rather than the historical finding corpus.
