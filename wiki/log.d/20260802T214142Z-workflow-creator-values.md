# 2026-08-02 — Bound workflow-creator values

- Added a packaging-owned candidate that copies hostile JSON-shaped Ruby
  graphs through load-captured core operations into fresh recursively frozen
  snapshots and sorted UTF-8 canonical bytes. Alternate `Data` factories are
  non-public, so `Values.capture` remains the sole ordinary snapshot factory.
- Added bounded text, relative-path, exact-secret, and token-pattern
  projections over snapshot-owned values; collision checks are linear and
  overlapping redactions use one fixed-size difference mask instead of
  rescanning or filling every matched span. Multibyte exact-secret overlaps are
  searched through byte-semantic copies; complete and truncated PEM bodies are
  fully redacted, and unsafe tilde, option-like, and control-byte paths fail.
- Added deterministic canonical-property, direct/module/refinement dispatch,
  post-load core replacement, exact resource boundary, and high-frequency
  secret proofs. Impossible direct Hash cardinality now fails before any key
  encoding, ambiguous `ASCII-8BIT` input fails closed, and captured allocation
  plus initialization resists post-load constructor replacement.
- Registered the zero-consumer U1a1v staged prerequisite with its single
  `U1a1c` removal fence and candidate clean-load proof. Catalog validation now
  permits zero consumers only for such a fenced candidate, while focused graph
  proof pins it as the sole current exception. Clean-load proof exposes the
  repository root only to non-`lib` entrypoints; creator schemas, consumers,
  custody, mutation, process, and live behavior remain unchanged.
