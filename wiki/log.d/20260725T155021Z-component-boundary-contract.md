# 2026-07-25 — Establish the component boundary contract

**Why:** Agents needed one current, machine-checkable map of Hive's reusable
mechanisms before later refactors could safely route consumers through stable
internal APIs.

**Change:** Added `config/component-boundaries.yml` with the seven retained
components, their ownership, entry points, public contracts, dependencies,
state/schema/lock responsibilities, consumers, authority, recovery surfaces,
wiki pages, tests, and maturity. U1 establishes the catalog and promotion
guard: all seven entries remain `candidate`. Attempts admission records the
existing `Hive::Attempts::API` slice, while U2 owns reconciling direct daemon
lifecycle construction of durable internals before it can become
`boundary-ready`.

**Enforcement:** Added a test-only contract that validates catalog metadata,
repository-local paths, unique ownership, an acyclic dependency graph, bounded
migration exceptions, forbidden upward requires, direct construction of named
internals across production Ruby, and clean-process loading for boundary-ready
entry points. Literal `require_relative` calls and all component-owned Ruby
files participate in dependency checks. The static scan is explicitly an
architecture regression guard, not a security sandbox; U1 does not overstate
it as proof that the existing Attempts lifecycle is already fully routed
through its admission facade.

**Docs:** Added [[component-boundaries]], linked it from the wiki index, recorded
the focused command in [[testing]], and updated ADR-038. No component was
packaged, versioned, tagged, published, or moved to another repository.
