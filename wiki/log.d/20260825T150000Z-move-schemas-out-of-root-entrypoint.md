## Schema ownership moved out of the root entrypoint

- Moved the entire `Hive::Schemas` namespace (`SCHEMA_VERSIONS`,
  `ErrorEnvelope`, `EnvelopeEmitter`, and the closed enums) verbatim from
  `lib/hive.rb` into its own `lib/hive/schemas.rb`; the root entrypoint
  keeps only a `require_relative` so the public constant path is
  unchanged for every `require "hive"` consumer.
- Only `schema_dir`'s relative depth changed (one level deeper) so
  `schema_path` still resolves to the published `schemas/` directory;
  pinned by regression tests asserting dedicated-file ownership,
  exactly-once loading, and unchanged schema resolution.
- The daemon ADR-031 drift fingerprint already resolves its target file
  through `Hive::Schemas.method(:schema_path).source_location`, so it
  followed the move automatically; its comment and the daemon wiki page
  now say so instead of hardcoding `lib/hive.rb`.
- Updated stale file-location references in [[state-model]]
  (`EnvelopeEmitter`) and [[modules/daemon]] (drift fingerprint).
