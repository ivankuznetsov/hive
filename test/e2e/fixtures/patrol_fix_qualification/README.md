# Patrol Fix qualification corpus provenance

`corpus.json` freezes eight labeled historical cases, two for each production
LLM gate. The source records themselves are intentionally not copied into the
repository: they contain untrusted project evidence and are larger than the
bounded gate context. Each case instead retains the immutable source identity,
SHA-256 of the exact source bytes, target revision, and a human label rationale.

The 2026-08-21 capture read ordinary records from:

```text
/home/asterio/Dev/hive/.hive-state/patrol/findings/<source_identity>.json
```

and Architecture v4 records from:

```text
/home/asterio/Dev/hive/.hive-state/refactor_patrol/v4/jobs/<source_identity>.json
```

The capture command used Ruby `File.binread`, `JSON.parse`, and
`Digest::SHA256.hexdigest(bytes)` to print the record id, exact byte digest,
and target revision. Corpus validation proves the frozen provenance shape and
digest syntax; a live qualification operator must re-audit those triples
against retained local records before treating the run as historical-source
evidence. Missing source bytes do not turn a case into synthetic evidence.
