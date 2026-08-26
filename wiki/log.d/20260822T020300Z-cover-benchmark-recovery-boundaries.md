# Cover benchmark recovery boundaries at the aggregate gate

- Added focused coverage for oversized OpenCode export diagnostics, invalid
  `--complete-execute` markers, failed clean-exit promotion, and every guarded
  execute-residue recovery rejection.
- These tests close the ten lines reported by the exact 100% aggregate coverage
  gate after the benchmark runtime branch was rebased onto current `main`.
