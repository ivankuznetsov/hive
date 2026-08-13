# Remove unused capture-policy overrides

- Removed the uncalled `CapturePolicy#promote!` and `#demote!` APIs and their
  private override-record builder.
- Capture applicability remains deterministic and generation-bound; receipts
  retain `override: nil` for schema compatibility, and live capture validation
  is unchanged.
