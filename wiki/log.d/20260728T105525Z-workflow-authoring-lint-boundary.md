# Extract the workflow authoring lint boundary

- Kept `WorkflowPackage::AuthoringLint` as the exact compatibility facade while
  separating bounded package reads, format-specific command extraction,
  immutable network observations, and finding evaluation.
- Preserved the characterized finding bytes, phase order, NUL-joined
  fingerprints, permission-hash insertion order, pop-newest limit sentinel,
  suppression, deduplication, final sort, and scanner-error collapse.
- Added the boundary-ready Workflow Authoring Lint component with Publisher as
  its sole production consumer and kept `SecurityScanner` as a distinct
  diagnostic engine.

**Pages:** [[modules/workflows]] [[component-boundaries]]
