---
title: Reuse captured config in operational status
module: status
tags: [status, performance, config, daemon]
---

Concise operational status now derives `daemon.enabled` from the workflow
generation captured for its full task scan. Each initialized project therefore
passes through `Hive::Config.load` once per operational scan instead of parsing
the same project config again for daemon context. Adapters that supply an
existing status payload keep the context-only read and do not start another
workflow-generation scan.
