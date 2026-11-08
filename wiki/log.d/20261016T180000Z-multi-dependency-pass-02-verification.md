---
title: Verify the unreviewed multi-dependency fix pass 02
date: 2026-10-16
---

- Merged main into the multi-dependency branch and dropped the branch's
  unrelated e2e incident aggregate loosening (40 s) and its fragments; main's
  36-second cap stands. The dependency ADR is renumbered to ADR-056.
- Invalid list `depends_on` evidence still keeps its shape, but non-finite YAML
  floats inside it are rendered as text so `DependencySnapshot.semantic_fingerprint`
  no longer raises `JSON::GeneratorError` for `depends_on: [a, .nan]`.
- `DependencySnapshot.branch_refs_for` now runs the git branch inventory only
  for valid same-project scalars; cross-project and invalid scalars skip it.
