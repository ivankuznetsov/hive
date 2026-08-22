## Feature-merge targeted Architecture Patrol

- Merged-PR intake now captures bounded title/body/label/author/file-patch and
  controller-publication provenance, closes obvious irrelevant or recursive
  Patrol merges deterministically, and queues ambiguous merge identity in a
  durable strict `feature|skip` classifier.
- Classifier calls run asynchronously as supervised Patrol scans with the
  selected profile's normal trusted execution posture. Provider retry times
  extend durable backoff; malformed output retries, and permanent/exhausted
  failures remain visible rather than becoming `skip`.
- Accepted classifier rows form the only unclaimed post-merge queue. Current
  main is mapped at claim, overlapping slices coalesce for ten minutes up to
  eight merges/512 paths, and oversized scopes split without dropping path or
  merge provenance. Only synthetic batch owners create v3 PR manifests, v4
  JobStore rows, and collision-free merge events; no staging member jobs or
  alias lifecycle rows exist.
- Existing immutable PR-manifest v2 artifacts remain readable for exact
  delivery adoption. This is a narrow manifest compatibility path, not a
  compatibility reader for obsolete JobStore bytes.
- Classification and batch records revalidate their content-derived source,
  path, batch, and owner identities on every read, so corrupted durable bytes
  cannot enter batching or discovery under a valid-looking filename.
- Post-merge classification/discovery bypass scheduled Architecture allowance
  while retaining Patrol-scan concurrency and provider backoff. The active
  Architecture module no longer requests or grants GitHub issue mutation.
