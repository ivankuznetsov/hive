---
title: Preserve all envelope serialization policies
tags: [refactor, ci, envelopes, compatibility]
---

**Action:** Exact-head CI exposed a third pre-refactor error-envelope policy
outside the seven migrated commands: the shared emitter's existing daemon and
maintenance consumers warn when JSON generation itself fails, mark stdout as
handled, and then preserve the original typed failure. Replaced the temporary
boolean hook with an explicit three-way policy so legacy warning consumers,
silent `run`/`status`, and raising approve/findings/markers/stage-action
producers all retain their original behavior. The existing daemon-emitter,
Run/Status, and Approve tests pin each arm.
