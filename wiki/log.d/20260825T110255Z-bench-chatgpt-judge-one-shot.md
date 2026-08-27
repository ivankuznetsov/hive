---
title: Keep ChatGPT-backed Codex judges one-shot without dropping auth
date: 2026-08-25
tags: [bench, codex, chatgpt, judge, isolation]
---

ChatGPT-backed Codex benchmark judges now share the OpenRouter route's
ephemeral session, ignored user config and rules, and empty temporary working
directory. This excludes project `AGENTS.md` instructions and configured agent
integrations from scoring. The ChatGPT child deliberately retains the
operator's `CODEX_HOME` so subscription authentication continues to work;
OpenRouter continues to replace it with a private temporary home because that
route authenticates directly from its provider environment.

The focused regression proves that the ChatGPT auth home survives the call,
the temporary workspace is removed, and the isolation flags plus Sol-ultra pins
reach the child. An authenticated ChatGPT Sol-ultra capacity probe returned the
requested JSON score directly from an empty workspace.
