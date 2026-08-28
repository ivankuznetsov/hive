# Fetch rollback no longer wipes un-owned destinations

**Problem:** A patrol finding showed that `RegistryClient#fetch`'s blanket
`rescue StandardError` ran `FileUtils.rm_rf(destination)` on every failure,
including failures raised *before* the method wrote anything to the
destination — source parsing and the "registry destination must be empty"
guard. A caller pointing `fetch` at their own non-empty directory lost its
entire contents when the fetch failed for an unrelated reason (bad source
string, unreachable registry).

**Root cause:** The rescue clause could not distinguish failures that occurred
before the method took ownership of the directory from failures during
materialization that the method itself caused. Unconditional cleanup was only
correct for the second class.

**Fix:** `fetch` now tracks ownership with two locals set immediately before
materialization begins: `owned_destination` and `destination_preexisted`. The
rollback removes the destination and restores an empty directory only when the
method owned it; pre-ownership failures (source parsing, emptiness guard,
clone, catalog resolution) leave the caller's directory untouched.
`Publisher#package` needed no change — its emptiness guard raises before any
writes and it has no destructive rescue — but a regression test pins that
behavior too.

**Practice:** when a method adopts cleanup/rollback semantics for a path it
does not create, scope the rollback to the phase after ownership is taken and
record whether the path pre-existed so it can be restored rather than deleted.

Regression tests: `test_fetch_preserves_pre_existing_destination_on_pre_ownership_failures`
(registry_client_test) and `test_package_preserves_pre_existing_destination_on_pre_ownership_failures`
(publisher_test).
