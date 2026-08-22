---
title: Simplify Patrol Fix controller and validation seams
type: log
---

- Added descriptor-owned `controller: :patrol_fix` capability for the built-in Patrol Fix workflow and removed the generic runtime's scattered workflow-id predicate.
- Centralized strict Inbox/Review report parsing and exact Review/Publish worktree snapshot validation while preserving each schema, route set, custody binding, and diff digest contract.
- Removed the duplicated launch-budget mode table; configured daily allowance is authoritative and `patrol.mode: off` now grants zero discovery launches.
- Kept historical Architecture Patrol issue-action and policy fields readable and fail-closed because their deletion requires an explicit storage/cutover migration.
