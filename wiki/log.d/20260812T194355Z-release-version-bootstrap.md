## [2026-08-12T19:43:55Z] release — isolate tag version bootstrap

**Action:** Made the tag-time release selector read `Hive::VERSION` from its
dependency-free leaf with RubyGems disabled, and pinned that bootstrap in the
release contract.

**Why:** Loading the top-level Hive runtime before candidate dependencies were
installed made a proven release fail selection when `agent_cli_runtime` became
a published runtime dependency.
