# 2026-07-25 — Record the Hive-first component boundary and future gem strategy

**Why:** Hive contains reusable mechanisms with plausible value outside the product, but splitting repositories or creating gems before their contracts are proven would reduce agent navigability and freeze accidental coupling.

**Decision:** Added ADR-038 and two implementation-ready plans. Hive remains the canonical monorepo and first consumer; `Hive::Attempts::API` is the reference boundary; UserService is the next internal extraction; later candidates proceed one component per PR and may remain internal. Standalone packaging is gated on a stable boundary, concrete non-Hive demand, independent artifact proof, and maintenance ownership. Any future component stays under `components/`, uses an independent version, and publishes only through an explicit component-scoped release that cannot match Hive's root tag trigger.

**Plans:** `docs/plans/2026-07-25-001-refactor-internal-component-boundaries-plan.md` covers internal API, dependency, state, compatibility, consumer, testing, and wiki boundaries. `docs/plans/2026-07-25-002-feat-standalone-component-gems-plan.md` covers qualification, package layout, path dogfood, exact artifact proof, release authority, remote verification, and the publish-before-Hive-cutover sequence.

**Scope:** This strategy record covers documentation and planning only. It
does not imply a package directory, gemspec, public name, version, tag,
publication, release, deployment, or compiled `wiki/log.md` change.
