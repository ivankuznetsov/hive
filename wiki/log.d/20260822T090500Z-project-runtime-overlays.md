# Project evidence runtime writes are ephemeral

**Problem:** Live Pi evidence started Webmail's Rails server against writable
binds of the implementation worktree's real `log/`, `storage/`, and `tmp/`
directories. Seeding the browser flow wrote Active Storage blobs under
`storage/as/`, dirtied the otherwise frozen worktree, and made later evidence
identity validation reject an attempt that had produced valid media.

**Change:** `ProjectCommandSandbox` now seeds conventional runtime directories
into writable overlay directories and bind-mounts those copies over the
read-only source paths. A CaptureToolkit attempt shares one overlay root across
its isolated terminal commands and managed application server, so terminal
seeding remains visible to browser capture without persisting any runtime byte
to the implementation worktree. Teardown verifies controller ownership and
removes the overlay root.

Focused tests prove seeded state and cross-sandbox reuse, and a real bubblewrap
server test proves a write visible inside `tmp/` never appears in the source.

See [[stages/artifacts]].
