---
title: Refresh Rack after bundler-audit advisories
date: 2026-11-01
tags: [dependencies, security, ci]
---

- Updated the root lockfile's transitive Rack resolution from 3.2.6 to 3.2.8.
  The current advisory database flags the former for four Rack advisories, all
  remediated by the 3.2.8 patch release; no direct dependency constraint or
  application behavior changed.
