# 2026-07-27 — Make Agent CLI Runtime mirror provenance fail closed

**Why:** The first mirror implementation let an unqualified release ref prefer
a same-named branch, executed a stale mirror-side projector, compared two trees
produced by that same projector, preserved all stale administration when the
canonical set disappeared, and relied on a mutable live release tag.

**Change:** Mirror sync now executes the projector from canonical Hive and
requires the complete canonical administration set before mutation. Mirror
release checkout uses the fully qualified component tag and the component
release preflight. Its expected tree comes from an independent Git archive of
the canonical tag, while the actual tree uses the current canonical projector.
The workflow also refuses release unless the live mirror has an active
`refs/tags/v*` ruleset blocking updates, deletion, and non-fast-forward
movement.

**Boundary:** Hive remains the only projection and release authority. The
mirror may create a verified tag once, but neither a later workflow run nor a
repository writer may replace or delete that published snapshot.
