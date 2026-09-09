---
date: 2026-09-09
slug: portable-evidence-sandbox-libraries
---

- Managed evidence command sandboxes now mount existing host system directories
  read-only instead of synthesizing Arch-specific `/lib64` and executable links.
  Ubuntu keeps its ELF loader under `/usr/lib64`; redirecting `/lib64` to
  `/usr/lib` prevented both shell and Ruby evidence commands from starting.
