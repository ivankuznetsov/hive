# 2026-10-02 — Accept bounded APFS replay control links

- The second hosted macOS replay-portability run created and validated its
  owner-private shard files, then rejected the unchanged control directory at
  final admission validation because APFS counts ordinary directory entries in
  `st_nlink`.
- Replay control custody now retains the strict one-or-two-link rule on
  non-Darwin hosts while accepting Darwin link counts through 258: the bounded
  256-shard namespace plus the two special directory entries. Exact shard
  owner, mode, type, size, link-count, and descriptor/path binding checks remain
  unchanged.
- A focused replay-safety regression simulates the APFS count increasing as
  persistent shards are created and rejects counts beyond the bounded
  namespace. A green hosted macOS run for the corrected commit remains
  outstanding.
