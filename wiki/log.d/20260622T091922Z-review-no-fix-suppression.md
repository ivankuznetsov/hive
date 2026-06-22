## [2026-06-22T09:19:22Z] review — suppress re-emitted triage no-fix findings

**Action:** Added `Hive::Stages::Review::Suppression`, a base-SHA-bound `reviews/suppressed.md` artifact, and review-loop wiring that strips active suppressions before triage and seeds new suppressions from checked `RESOLVED/NO-FIX:` triage lines. The fingerprint is intentionally loose (`severity + normalized file refs + normalized title`, with line numbers and body/justification excluded) so a no-fix finding re-emitted on the next pass does not re-enter triage. `suppressed.md` is operator-visible, hand-editable, classified as orchestrator-owned, and included in the fix protected-file snapshot.

**Tests:** Added unit coverage for fingerprint normalization, base reset, active-key parsing, deduped append, strip, and seed behavior; added review-loop integration coverage for post-fix convergence by pass 2, High escalation staying unsuppressed, different-title non-suppression, and fix-agent tampering of `reviews/suppressed.md`.

**Docs:** Updated [[stages/review]], [[state-model]], [[modules/protected_files]], and [[testing]].
