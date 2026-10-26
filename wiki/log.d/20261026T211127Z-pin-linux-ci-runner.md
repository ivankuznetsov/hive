---
date: 2026-10-26
slug: pin-linux-ci-runner
pages: [dependencies, gaps]
---

# Pin Linux CI to Ubuntu 24.04

`ubuntu-latest` moved CI to Ubuntu 26.04, where the repository's pinned
Playwright 1.60.0 rejects Chromium installation and bubblewrap-backed artifact
tests became unreliable. All Linux jobs in the canonical CI workflow now use
`ubuntu-24.04`, the prior green image, while a future dedicated upgrade can
validate Ubuntu 26.04 compatibility.
