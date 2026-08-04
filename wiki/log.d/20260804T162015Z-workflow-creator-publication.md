## 2026-08-04 — Workflow creator receipt publication boundary

**Change:** Added the typed `WorkflowCreatorEvidence` facade and its private,
creator-specific receipt publisher. The facade accepts only a bundle directory,
derives the primary filename from the frozen vocabulary, validates canonical
non-passing receipts through the merged creator core, and owns descriptor-bound
initialization, compare-and-swap replacement, bounded recovery, cleanup, and
durability.

**Safety:** Publication uses held directory descriptors plus native
`openat`/`linkat`/`renameat`/`unlinkat`, owner-only regular files, no-follow and
nonblocking opens, file-before-publication fsync, directory-after-cleanup fsync,
one held-directory-descriptor replacement lock, and fail-closed
link/path/type/permission checks. The Ripper construction fence
now recognizes parenthesized and parenthesis-free `.new` calls and permits the
private publisher only from its public facade.

**Proof:** Focused tests cover exact and conflicting retries, both transient
cleanup orders, concurrent recovery, interrupted and replacement crash gaps,
link ambiguity, fsync order and failure, parent rebinding, bounded FIFO/special
enumeration, typed native errors, cleanup, and Linux/macOS flag tables. Release
candidate source identity now includes both publication files.

**Authority:** The temporary protected smoke adapter emits only a typed
non-passing U14 custody gap. It does not select credentials, execute the future
U14 transaction, or claim U15 live success.
