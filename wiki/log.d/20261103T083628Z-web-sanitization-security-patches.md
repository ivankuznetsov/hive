---
title: Patch web parser and sanitization dependencies
date: 2026-11-03
tags: [dependencies, web, security, ci]
pages: [dependencies]
---

The CI web bundle audit failed on Loofah 2.25.2, Nokogiri 1.19.4, and
rails-html-sanitizer 1.7.1. A conservative patch relock updates only these
three gems and their dependency requirements: Loofah 2.25.3, Nokogiri 1.19.7
on all eight existing native platforms, and rails-html-sanitizer 1.7.2.
Both root and web lockfile audits pass locally after the update.
The frozen web bundle resolves, and the existing application helper and task
integration tests pass with 81 runs, 597 assertions, and no failures or errors.

[[dependencies]] records the patched versions and the separate web audit.
