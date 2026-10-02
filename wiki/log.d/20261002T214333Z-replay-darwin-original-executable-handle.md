# 2026-10-02 — Launch Darwin replay from the verified executable handle

- Hosted macOS rejected native replay through the `/dev/fd` alias of a Ruby
  duplicate even after that duplicate was made inheritable.
- Native replay now temporarily clears close-on-exec on the original,
  identity-checked `O_EXEC` handle, executes its already-live alias, and restores
  close-on-exec immediately after spawn.
- Portability coverage verifies that spawn receives the verified alias, sees the
  original handle as inheritable, and leaves descriptor isolation restored.
