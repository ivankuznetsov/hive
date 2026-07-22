---
title: Audit queued Rails head and bounded web resources
date: 2026-07-22T22:20:45Z
tags: [wiki, web, rails, puma, stimulus, testing, provenance]
---

Inspected all six queued commits and all 79 changed-path blobs with direct
`git show`. None of the supplied SHAs is an ancestor of the refresh branch.
Stable patch IDs establish that `153bed1d` is equivalent to the already
documented `96b06792` / `2fef1f47` Rails resource change, `163ed51e` to
`22d80d1b`'s server-rendered project-filter/test-isolation change,
`1941780d` to `d28377b2` / `eb8f6181`'s durable golden-path wait,
`5c86ad25` to `c0c6c147` / `72b95280`'s dispatch-writer coverage, and
`a46cd592` to `e1c41ea0`'s Brakeman metadata-only refresh. The queue manifest
for `163ed51e` is stale: its immutable diff has 19 project-filter paths, while
the listed bounded-resource paths belong to `ccfa7c03`'s 14-path diff.

Final branch head `ccfa7c03` adds the new contract. The permanent idea
composer shares the server's eight-image / 10 MiB limits, inspects at most 16
picker or clipboard entries, batches its `FileList` rebuild, avoids decoding
attachment previews, and releases staged browser files after a cancellable
true disconnect. Timed Turbo-frame polling yields while an earlier frame
request is busy. Shared request-limit constants configure both Rails and the
rendered client; Puma rejects declared bodies above the 81 MiB valid-idea
envelope before Rack and the Rails-only hook rejects chunked bodies at the
parsed-header boundary while closing the connection. Controller count/size
checks remain authoritative for admitted parsed uploads.

Updated [[active-areas]], [[architecture]], [[commands]], [[commands/drop]],
[[commands/web]], [[testing]], and [[gaps]] with the rebased lineage, focused
test evidence, current-default boundary, and missing deployed slow-client /
reverse-proxy smoke. Page coverage remains 95, so [[index]] did not change.
Compiled [[log]] was not edited, and QMD was intentionally not run.

**Refreshed pages:**

- [[active-areas]]
- [[architecture]]
- [[commands]]
- [[commands/drop]]
- [[commands/web]]
- [[testing]]
- [[gaps]]
- [[log]]
