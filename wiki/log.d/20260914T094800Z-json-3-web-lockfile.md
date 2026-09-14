---
title: Synchronize the web path-gem lock after the JSON 3 update
date: 2026-09-14
---

Updated `web/Gemfile.lock` after `agent-cli-runtime` raised its JSON ceiling
to `< 4.0`. The frozen Rails CI bundle now resolves `json 3.0.2` and Rubocop
1.91.0, matching the path gemspec instead of failing during `bundle install`.
