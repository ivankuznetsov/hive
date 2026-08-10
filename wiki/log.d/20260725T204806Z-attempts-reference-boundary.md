# 2026-07-25 — Guard Attempts admission as the reference candidate

**Why:** The component catalog needed one enforced Hive-first reference slice
before later mechanisms could copy its boundary and verification discipline.

**Change:** Kept the existing `Hive::Attempts::API` admission slice as a
guarded reference `candidate` without adding lifecycle methods. The catalog
records its downward dependency on WorkLedger plus a U8-bounded exception for
the reciprocal edge where WorkLedger-owned `lib/hive/task_projection/store.rb`
requires and constructs `Hive::Attempts::Store`. It also records the complete
internal admission/lifecycle collaborator set and the exact Hive composition
or read-only consumer files that must still construct those internals.

**Enforcement:** Internal Attempts classes cannot be constructed from a new
production file. Existing construction is allowed only for an exact
file/constant pair with a recorded reason; stale authorizations and newly
listed files fail the component contract even for a candidate. Authorization
is file-granular and does not distinguish another call site inside an already
authorized composition root. A `boundary-ready` component cannot depend on a
candidate. The focused clean-process API proof, foreground/queue/successor
delegation, shared-store injection, v2 durable-record coverage, and one-off
migration tests remain the compatibility evidence.

**Scope:** Reconciliation, supervision, capacity, loss processing,
cancellation, export, and raw store operations remain internal. No gem,
package directory, version, tag, release, publication, deployment, or
repository split was introduced.

**Mainline sync:** Cataloged `TaskClosure` as another read-only canonical-store
consumer after its active-attempt verification landed on `main`; it does not
widen the admission facade.
