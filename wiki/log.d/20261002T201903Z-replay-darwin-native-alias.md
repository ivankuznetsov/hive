# 2026-10-02 — Preserve Darwin replay aliases through launch

- Interpreter-driven replay scripts now inherit their readable artifact on
  descriptor 9 (or 8 on collision), avoiding both spawn's low control slots and
  Bash's internal high-descriptor range.
- Native replay binaries execute through the already-live `O_EXEC` alias rather
  than an alias created later by a spawn file action.
- Portability probes now open `/dev/fd` aliases before checking descriptor
  identity because Darwin pathname stat metadata describes the synthetic entry.
