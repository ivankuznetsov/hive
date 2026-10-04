# 2026-10-02 — Validate Darwin replay execution through held descriptors

- Darwin replay no longer reopens an already-`O_EXEC` descriptor through the
  synthetic `/dev/fd` filesystem during preflight. The executable descriptor
  was already opened relative to the pinned parent and identity-checked.
- The exact `/dev/fd/<held-fd>` mapping must still exist, and launch-time
  execute-mode validation now reads the held descriptor's `fstat` metadata,
  including the invoking process's permission class, instead of unreliable
  synthetic pathname metadata.
- Native-adapter tests directly cover executable open success and cleanup on
  missing or invalid components. A green hosted macOS run remains outstanding.
- Portability tests reject a missing fixed Darwin executable alias and prevent
  launch from querying synthetic pathname metadata.
