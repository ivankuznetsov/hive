## [2026-08-25T11:03:54Z] implementation identity — centralize selection materialization

**Action:** Fixed an architecture-patrol finding where persisted identity
materialization was duplicated: `Store#selection_from_projection` and
`Reconstructor#selection_from` each independently branched on routing
internals to decide how durable identities regain native arguments, parallel
to the routed-versus-flat representation decision already owned by
`Resolver#build_selection`. Added `Resolver#materialize_persisted` as the
single authority (routed selections carry no native argv and replay frozen
routing metadata through `routing_arguments`; legacy flat identities re-derive
typed arguments from their profile) and made both `Store` and `Reconstructor`
delegate to it. Regression coverage proves delegation from the projected
reconstruction path and locks the routed/flat materialization contract on the
resolver itself.

**Refreshed pages:**
- [[modules/agent_profile]]

**Files:** `lib/hive/implementation_identity/resolver.rb`,
`lib/hive/implementation_identity/store.rb`,
`lib/hive/implementation_identity/reconstructor.rb`,
`test/unit/implementation_identity/resolver_test.rb`,
`test/unit/implementation_identity/reconstructor_test.rb`
