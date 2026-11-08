## 2026-11-07 — Client connection context foundation

- Added separate versioned context and credential stores beneath the client
  configuration root, with locked atomic writes and private permissions.
- Added fresh metadata verification seams, HTTPS URL validation before stdin
  credential reads, pinned installation identity, and visible failures for
  corrupt or future-version configuration.
- Resolve context before runtime activation or local project discovery in both
  native executable entry paths. Reject remote local-only/unknown commands,
  preserve explicit local overrides and literal task text, and announce local
  mutation authority and targets on stderr.
- The internal context command owns the registered `hive-context.v1` JSON
  contract. Public context registration waits for the API and transport.
- Pages: [[cli]].
