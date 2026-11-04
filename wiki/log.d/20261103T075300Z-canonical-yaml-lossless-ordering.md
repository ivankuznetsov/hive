# 2026-11-03 — Lossless Honeycomb manifest ordering

- `CanonicalYAML.dump_manifest` now carries complete structural paths through
  maps and sequence items. Known schema roles keep their established field
  order and append every lexical remainder; generic mappings sort all string
  keys recursively. Arrays keep their positions, input objects remain
  unchanged, and unsigned dumping omits only root `release_sha256`.
- Non-string manifest keys fail uniformly before sorting. The reader narrowly
  converts full/unsigned dump-call `ArgumentError`s to
  `PackageError` / `manifest.non_canonical`, preserving unrelated exceptions
  and existing YAML/encoding diagnostics. Root/core shape validation and
  contextual owned-extension validation retain their separate owners.
- A reader-only legacy-v1 byte matcher returns the paired unsigned digest
  input. Valid historical and newly submitted hand-authored extension orders
  retain their exact bytes and release/package identities. The legacy accepted
  set contains the new canonical form; admission remains unchanged while
  Hive's own builder converges on one form. Generic dump and `hive-module/v1`
  bytes remain unchanged. No package migration, publication, or release occurs.
- Fixtures captured before production changes pin rich builder bytes, both
  recommendation entry orders, unordered extension descendants, module bytes,
  and both digest layers. Publisher recovery also pins pre-change receipt
  digests with authored inputs still available; `publisher.rb` is unchanged.
  Store, gateway, client, submission, publish CLI and install/update lifecycle
  tests prove exact byte retention and digest handoffs. Serializer/reader
  changed-source coverage is exactly 100% per file.
- Focused behavioral, consumer, lifecycle, module and Wiki checks pass, as does
  repository-wide RuboCop. The broad `bin/test --all` checkpoint is red: Hive
  partitions report four failures and twenty-three errors, while standalone
  Agent CLI Runtime passes. The exact OpenCode lifecycle success test reproduces
  `Errno::ESRCH` at `invocation_process_custody.rb:112` on untouched base
  `966211001e` and the implementation. Other broad failures are not all
  independently baselined. This exceeds the plan's allowed baseline exception;
  completion remains blocked and no execution-complete trailer is recorded.
- Contract and evidence ownership: [[modules/workflow_package]], [[testing]].
  Live-registry inventory remains an explicit gap in [[gaps]].
