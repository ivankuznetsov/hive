# 2026-10-02 — Inherit a Darwin native replay duplicate

- Hosted macOS showed that `close_others: false` does not preserve an `O_EXEC`
  handle already marked close-on-exec, so its `/dev/fd` alias disappeared before
  native image lookup.
- Native replay now duplicates the pinned executable handle before spawn and
  clears close-on-exec only on that launch duplicate. The parent closes its copy
  after spawn while the artifact inherits the selected descriptor alias.
- Portability coverage verifies the spawned alias is the non-close-on-exec
  duplicate and that the parent closes it after spawn returns.
