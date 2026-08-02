---
title: Require one complete workflow creator source stream
type: fix
created: 2026-08-02
tags: [workflow-creator, release-candidate, gzip, tar, verification]
---

- Closed a verifier/consumer mismatch in which Ruby inspected only the first
  gzip member while ordinary tar consumption continued into a second member.
- Source verification now drains the first member under the expanded-byte
  budget, permits only bounded 512-byte-aligned zero tar end padding, and
  rejects unused or trailing compressed bytes.
- Added a characterization that first proves normal tar lists a benign entry
  from the second member and then requires Hive to reject the artifact.
- Added missing, nonzero, oversized, and non-block-aligned end-padding coverage
  and retained an actual `git archive` acceptance probe so the stricter
  single-stream rule matches produced bytes.
