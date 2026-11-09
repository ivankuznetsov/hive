---
title: Proposal CI coverage and quarantined-index digest resolution
type: change
created: 2026-11-09
updated: 2026-11-09
tags: [proposals, testing, coverage, recovery]
---

Proposal coverage now exercises the remaining immutable-record, lineage,
quota, identifier, quarantine-compensation, filesystem-race, and Git index-race
guards. The quarantined source-index diagnostic explicitly resolves Ruby's
top-level `Digest` namespace, so loading the sibling `Hive::Commands::Digest`
command first cannot break proposal discovery. The browser-history system test
uses Capybara's synchronized field assertion while Turbo completes restoration
of the permanent composer.
