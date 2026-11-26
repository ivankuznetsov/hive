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
- `CanonicalYAML.key_text` quotes YAML 1.1 boolean/null keyword keys
  (`true`/`false`/`yes`/`no`/`on`/`off`/`null`, case-insensitive) so Psych
  round-trips every string key losslessly without collapsing or coercing
  keyword keys. `RegistryManifest.load_bytes` and
  `CanonicalYAML.legacy_v1_release_input` compare validated UTF-8 bytes
  encoding-safely so non-ASCII UTF-8 manifests loaded from disk (`ASCII-8BIT`)
  verify identically for both canonical and legacy-v1 forms.
- Focused workflow-package, module-package, lifecycle, and Wiki suites pass,
  along with 100% changed-source coverage and RuboCop on the rebased branch.
- Contract and evidence ownership: [[modules/workflow_package]], [[testing]].
  Live-registry inventory remains an explicit gap in [[gaps]].
