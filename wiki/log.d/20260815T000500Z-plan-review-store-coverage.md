## 2026-08-15 — Plan review store fail-closed coverage

`test/unit/plan_review/store_test.rb` now exercises every guard clause in
`lib/hive/plan_review/store.rb` that had no test behind it:

- CAS and lineage rejections — projection versions that do not follow the
  observed version, a publish against a version that was never observed, and
  an unrelated review trying to take over the current pointer.
- Corrupt JSON on both `current.json` and a review `manifest.json`.
- Oversized JSON artifacts (over the 2 MiB cap) and a 256-character basename,
  which `SAFE_SEGMENT` permits but the filesystem rejects as `ENAMETOOLONG`,
  reaching the `SystemCallError` rescue in `write_immutable`.
- Unsafe path segments in decision targets, plus `Symbol` values flowing
  through `sanitize`.
- Every malformed artifact-reference shape: non-hash, symbol keys (which pass
  the key-name check but raise `KeyError` on `fetch`), `..` traversal, `~`
  expansion outside the root, and a sha256 mismatch.
- Directories outside the task folder, and an unwritable task folder.

See [[modules/plan_review]] and [[testing]].
