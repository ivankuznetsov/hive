---
title: Harden outcome-evidence capture custody and Web reads
date: 2026-08-14
tags: [artifacts, evidence, security, web]
---

- Replaced the producer-visible browser gateway socket with a bounded
  controller-owned FIFO mailbox used for both browser and terminal operations.
- Enabled Codex managed limited networking with local binding and no admitted
  domains, moved browser home/cache/download state outside the producer write
  root, and raised the packaged Codex pin and capture minimum to `0.147.0`.
- Added controller path/type/size/digest receipts for screenshot, video, and
  terminal files. Producer-written lookalike media and post-capture mutations
  now fail before custody transfer.
- Enforced media bounds before hashing/copying and protected cleanup from
  deleting pre-existing custody roots.
- Added a metadata-only outcome-evidence package projection for Hivebox listing;
  selected downloads still revalidate their exact retained size and digest.
- Documented the authorized read-only `OutcomeEvidence::Store` use of Attempts
  storage for durable-attempt ownership checks.
