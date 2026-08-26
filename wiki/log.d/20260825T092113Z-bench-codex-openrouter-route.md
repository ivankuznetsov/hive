---
title: Route a pinned Codex judge through OpenRouter
date: 2026-08-25
tags: [bench, codex, openrouter, judge, recovery]
---

Bench campaigns may now keep the logical Codex judge identity and reasoning
effort while explicitly routing its CLI request through OpenRouter. The route
is opt-in through `judges.codex.provider: openrouter` and requires an explicit
`provider_model`; the existing ChatGPT subscription route remains the default.

The API key stays in the environment, the Codex argv carries only the name of
that environment variable, and new judge records or deliberation transcripts
record both the selected provider and provider model. The judge-stage runtime
guard requires this routing capability before executing a campaign that was
refreshed from current Hive templates.
