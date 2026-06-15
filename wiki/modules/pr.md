---
title: Hive::Pr
type: module
source: lib/hive/pr.rb
created: 2026-06-15
updated: 2026-06-15
tags: [module, pr, tui, status, bot, telegram]
---

**TLDR**: Tiny pull-request display helper. `Hive::Pr.number(url)` turns a pull-request URL into a short `#<number>` token for operator UIs without making network calls or treating the URL as workflow proof.

## API

```ruby
Hive::Pr.number(url) # => "#561" or nil
```

Accepted shapes are URLs or path-like strings ending in `/pull/<digits>`, with an optional trailing slash, query string, or fragment. Blank input, issue URLs, non-numeric pull segments, and PR subpages such as `/pull/561/files` return `nil`.

## Consumers

- [[commands/status]] uses it in `Hive::Commands::Status#pr_cell` to render the fixed PR slot in text status and archive rows from `tasks[].pr_url`.
- [[commands/tui]] uses it in `Hive::Tui::Views::TasksPane#pr_cell` to render the fixed PR column from `hive-status` `tasks[].pr_url`.
- [[modules/bot]] uses it through `Hive::Bot::Format.html_pr_link` for `/status`/`/queue` list rows and the `ready_for_review` Telegram push.

## Boundaries

`Hive::Pr` is deliberately not a GitHub API client. It does not validate owner/repo names, confirm that a PR exists, distinguish open/closed/merged states, or advance workflow state. It formats values that [[commands/status]] already emitted; network-backed PR operations remain in [[modules/gh]].

## Tests

- `test/unit/pr_test.rb` covers numeric extraction plus nil returns for missing, issue, non-number, and subpage URLs.

## Backlinks

- [[commands/status]] · [[commands/tui]] · [[modules/bot]]
- [[modules/gh]]
