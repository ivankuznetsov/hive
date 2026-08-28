## [2026-08-28T15:54:14Z] plan review — recover exhausted mandatory transient series

**Action:** Made exhausted transient primary/adversarial reviewer series for
mandatory plans scheduler-owned. Hive now persists a recovery reset and retries
on a deterministic exponential schedule from five minutes up to 24 hours;
legacy blocked coverage records with an attempted transient leg re-enter the
same path automatically.

**Why:** Dogfood of the capability-recovery release showed that the original
Screenote image-attachments task had two Grok timeouts with failed required
whole-document coverage, not an unsupported binary. The daemon therefore kept
classifying it as an operator-owned reviewer-configuration block even after
Grok recovered.

**Boundaries:** One invocation still obeys
`plan_review.attempts.max_transient`. Standard degraded review, disposition
verification, and planner-revision hard caps are unchanged. Only actual review
attempts create immutable artifacts; waiting ticks do not append evidence.

**Verification:** Added orchestrator coverage for two exhausted series followed
by automatic success, task-action coverage for the exact legacy blocker shape,
and checked the live Screenote task through the branch-local `hive task` reader.
