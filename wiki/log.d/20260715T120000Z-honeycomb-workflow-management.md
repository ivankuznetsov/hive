# 2026-07-15 — Add honeycomb workflow package management

**Action:** Extended `hive workflow` with install, local/remote/outdated list,
selector-aware single/all update, and ownership-aware remove for the fixed public
Honeycomb Git registry. Packages now resolve to immutable commits, pass exact
tree/manifest/descriptor/security validation, preserve their nested
`<id>/workflow.yml` layout, and record source/integrity/selector/security state
in `.hive-state/workflows/.honeycomb.lock`.

**Safety:** Mutations preview before approval, require `--yes` outside a TTY,
distinguish force from approval, protect built-in/unmanaged/dirty workflows, and
use a commit-locked same-filesystem journal to keep package files, lockfile,
index, and one scoped `hive/state` commit on the same revision. Update previews
include permission escalation and complete instruction diffs; uncertain removal
remains an explicit non-zero partial result.

**Verification:** Added focused registry, integrity, security, lock,
transaction/recovery, diff, command, schema, and loader/parser tests plus a
hermetic lifecycle integration suite backed by a local bare Git registry. User
and maintained-wiki documentation now define the catalog/package contracts,
offline list boundary, selector policy, approvals, recovery, and JSON schemas.
