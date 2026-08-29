---
title: Bind bench quota markers to the campaign runtime
type: fix
date: 2026-08-27
---

## Action

Generate and judge quota recovery now load Hive marker and cooldown code from
the campaign's immutable source runtime. This keeps dogfood stage-agent shells
from falling back to an older installed `hive-cli` gem after RubyGems environment
variables are scrubbed.

## Proof

Focused workflow tests execute both quota-marker helpers with `RUBYLIB` removed
and require canonical retry markers from the source checkout.
