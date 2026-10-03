# 2026-09-21 — Make sealed benchmark runners executable

Sealed plan runs could fail while Git indexed a controller-created 0600 activity
receipt: the controller runs as root, while its Git shim drops to UID 1000.
The shim now normalizes the mounted worktree ownership before the drop, while
Hive's custody checks remain authoritative for protected state.

Source-built runner images also lacked Betterleaks because the executable is a
release-packaged asset, not part of the source archive. The Docker build now
runs the checksum-verified packaging script before building the Hive gem.
