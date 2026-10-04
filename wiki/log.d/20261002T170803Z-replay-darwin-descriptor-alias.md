# 2026-10-02 — Verify Darwin replay aliases through opened descriptors

- The third hosted macOS replay-portability run reached descriptor alias
  selection, then rejected every `/dev/fd/<fd>` candidate because it compared
  the synthetic pathname stat directly with the held script descriptor.
- Darwin alias verification now opens `/dev/fd/<fd>` read-only, relies on the
  descriptor filesystem's duplicate operation, and compares the duplicate's
  descriptor stat with the pinned script identity. The verification duplicate
  closes before artifact launch, and Linux retains its pathname-stat check.
- A deterministic portability regression supplies mismatched descriptor-path
  metadata while preserving the opened duplicate identity. A green hosted
  macOS run for the corrected commit remains outstanding.
