# 2026-10-02 — Preserve native create modes on Apple Silicon

- The first hosted macOS replay-portability run reached admission but rejected
  every freshly created lock shard as unsafe. The native adapter had declared
  `openat`'s optional mode as a fixed fourth argument, which happens to work on
  Linux but does not follow Apple Silicon's variadic calling convention.
- Mode-bearing `openat` calls now use Fiddle's variadic signature and explicit
  type/value dispatch. This keeps replay shards at `0600` and also corrects the
  shared managed-directory file-creation primitive without weakening its
  no-follow or descriptor-relative boundary.
- `managed_directory_test.rb` pins both the variadic declaration and dispatch;
  the replay safety and portability suites remain the end-to-end regression
  checks. A green hosted macOS run for the corrected commit remains outstanding.
