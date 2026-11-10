## 2026-11-08 — Keep proposal artifact hashing in the root digest namespace

- Proposal source and lifecycle artifact reads now resolve `Digest::SHA256`
  from Ruby's root namespace, so loading the `Hive::Commands::Digest` CLI
  command cannot shadow the standard-library digest implementation.
- The existing proposal command coverage verifies the bounded artifact digest
  and live lifecycle paths that previously failed under the full-suite load
  order.
