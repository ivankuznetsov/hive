# 2026-09-21 OpenCode auth cache isolation

OpenCode benchmark cells now mount a writable per-cell tmpfs at
`~/.local/share/opencode` before binding the operator's auth file read-only.
This prevents Docker from creating a root-owned parent directory and blocking
OpenCode's disposable `repos` cache with `EACCES`.
