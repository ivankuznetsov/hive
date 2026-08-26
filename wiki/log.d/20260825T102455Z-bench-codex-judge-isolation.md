---
title: Isolate OpenRouter-backed Codex judges from operator agent context
date: 2026-08-25
tags: [bench, codex, openrouter, judge, isolation]
---

OpenRouter-backed Codex benchmark judges now run with an ephemeral session,
ignored user config and rules, a private temporary `CODEX_HOME`, and an empty
temporary working directory. This prevents personal plugins, skills, MCP
servers, memories, and project `AGENTS.md` instructions from expanding a
one-shot score request into a tool-using agent session. The temporary tree is
removed after both success and failure.

The ChatGPT-backed route retains its existing authentication home. The focused
regression records the isolated home and working directory during execution,
proves both are removed afterward, and pins the three Codex isolation flags.
An authenticated Ox Alpha OpenRouter probe returned the requested JSON score
directly through the packaged judge implementation.
