# Workflow publish review hardening

- Packaged the pinned Honeycomb lint fixture and SafeYAML parity corpus as
  runtime gem data.
- Made authored descriptor `x-hive` declarations the sole source for package
  tools, prompt assets, and optional inputs, while excluding authoring-only
  metadata from immutable package assets.
- Hardened publication recovery with no-follow state reads, complete PR
  pagination, evidence-based metadata-less adoption, exact blob/mode and
  retained commit-tree verification, fork-origin restoration, transaction-wide
  identity locking, and atomic expected-absent pushes.
- Aligned publish error/schema outcomes, post-effect ambiguity, configured
  catalogue branches, cleanup warnings, and listed-bundle GC eligibility.
