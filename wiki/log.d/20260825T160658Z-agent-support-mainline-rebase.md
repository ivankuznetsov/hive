---
title: Agent support mainline rebase
type: change
date: 2026-08-25
tags: [agent-support, opencode, rebase, runtime]
---

- Rebased the five built-in agent-support boundaries onto the current mainline
  without restoring provider-name dispatch in generic stages or `Hive::Agent`.
- OpenCode's patrol recovery, long sanitized exports, retry policy, structured
  provider-limit handling, tool-only completion, and typed artifact permissions
  remain owned by `Hive::AgentSupport::OpenCode`; core retains only generic
  bounded process capture and cleanup.
- Regular-file inspection capture now treats stdout and diagnostic stderr as
  independent bounds, so a truncated diagnostic cannot be accepted as complete.
- Custom profile compatibility remains intact: legacy OpenCode configuration
  keywords delegate to its typed support configuration, Pi terminal protocols
  still resolve lazily, and Claude keeps its omitted permission-preset defaults.
- The mainline isolated OpenRouter and ChatGPT Codex judge routes remain in the
  benchmark runtime and pass their focused regression suite.
