---
title: Decompose release-candidate orchestration after hosted dogfood
date: 2026-08-05
category: architecture
module: release-candidate
tags: [release, candidate, u8, orchestration, dogfood]
---

**Changed:** Reduced `HiveReleaseCandidate::Runner` to the stable public façade
and composition root over five internal owners: committed repository inputs,
baseline-cache authorization, gate execution, local-attempt persistence, and
remote-run orchestration. Existing public verbs, gate/evidence ordering,
locking, retry lineage, and blocker payloads remain at the façade. The remote
client also accepts GitHub's exact identical-compare response when
`head_commit` is omitted, and hosted retry admission binds the candidate SHA
and signed external evidence identity instead of GitHub's rewritten Check Run
details URL. Release selection uses the same immutable identity contract, so a
QA-ready Check remains selectable after that rewrite.

**Evidence:** Protected-main run `31005500332` retained the exact candidate and
terminal evidence with seven of fourteen required gates passing. Named retry
run `31006277887` failed closed before gate selection at the obsolete URL
assertion; a fresh post-merge targeted retry remains required. The campaign's
additional harness failures and the deliberately deferred hard-crash journal
are recorded in `wiki/gaps.md`. No tag, publication, deployment, or release
action occurred.
