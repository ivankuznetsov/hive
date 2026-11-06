## [2026-11-02T11:00:00Z] Prepare exact dependency edits

Added non-mutating dependency edit proposals, source-preserving YAML entry
editing, existing-plan assertion synchronization and graph overlays for existing
task identities. Focused tests cover comments, Unicode, CRLF, flow mappings,
duplicate keys, occurrence shape, self-reference, cycles and all-edge validation.

Execution stopped before the transaction and CLI units: never-run tasks lack
a supported authoritative operator activity binding. Recorded the prerequisite
in `wiki/gaps.md`; existing attempt validation remains unchanged.
