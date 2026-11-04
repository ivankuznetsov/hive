---
title: Root bundle raises the Active Support security floor
date: 2026-11-04
tags: [dependencies, security, bundler-audit]
---

- Updated the root lockfile from Active Support 8.1.3 to 8.1.4.1 and the web
  Rails family from 8.1.3.1 to 8.1.4.1 after the current Ruby advisory database
  reported Active Storage, MessagePack serializer XSS, and `safe_constantize`
  vulnerabilities. Compatible resolutions also update transitive `i18n` from
  1.14.8 to 1.15.2.
