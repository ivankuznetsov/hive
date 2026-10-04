# 2026-10-02 — Preserve close-on-exec for Darwin native replay

- Native replay no longer asks Ruby to self-map the held `O_EXEC` descriptor,
  which failed during spawn preparation on hosted macOS.
- The already-live `/dev/fd` alias is resolved while its descriptor remains
  close-on-exec; image replacement then closes that handle along with the other
  descriptor-pinned custody handles.
- Script replay keeps its verified child descriptor 9 or 8 mapping unchanged.
