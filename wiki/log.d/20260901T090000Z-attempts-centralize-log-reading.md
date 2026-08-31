---
title: Centralize attempt log reading in the repository
tags: [attempts, repository, log-archive, client]
---

`Attempts::Client` sniffed store capabilities (`respond_to?(:log_archive)`)
and, on the fallback path, independently resolved the physical frame file from
`logs_root` and judged availability with its own `File.file?` check. Consumers
therefore faced two unstated read contracts, and characterization tests had to
reconstruct the legacy filesystem-facing store interface alongside the real
archive-backed repository.

The repository now exposes one authoritative log-read contract:
`Repository#read_log(attempt_id, after_sequence:)` delegates to `LogArchive`,
whose custody-checked resolution already covers hot frames, sealed payloads,
and expiry. `Client` consumes that single contract unconditionally and no
longer imports `StreamLog`, resolves paths, or branches on capabilities.
Client characterization stores now satisfy only `fetch` plus `read_log`, and a
regression test pins that a store exposing just the repository read contract
drives frame replay and availability without capability sniffing.
