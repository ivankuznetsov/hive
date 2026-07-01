---
slug: claude-tmux-packaging-detector
created: 2026-06-29T10:54:27Z
---

**Action:** Documented the local validation path for unreleased
`hive-cli` packaging fixes that affect Claude tmux launch scripts: build the
real gem, install into an isolated prefix, run `hive doctor`, and replay the
affected `hive run` task from that install rather than copying scripts into the
installed gem by hand. Added the daemon drift caveat that systemd/launchd may
still point at an older `hive` binary until `hive daemon install --force`
rewrites the unit.

**Refs:** [[operating]]
