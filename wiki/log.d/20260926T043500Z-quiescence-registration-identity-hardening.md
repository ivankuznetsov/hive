# 2026-09-26 — Quiescence registration and identity hardening

- Detached Hive CLI children launched by `hive new`, the TUI, the bot, and the
  daemon now use a parent-created launch reservation, `bin/hive` launch gate,
  and exact child adoption handshake, so quiescence cannot pass through the
  spawn-to-registration gap or lose an unresolved child when its parent exits.
- Hivebox persists its supervisor PID and process-start identity before starting
  children. Independent controllers now discover that live supervisor from the
  installation state instead of depending on inherited environment.
- Minimal-init preview and `workflow validate` share one startup route
  classifier across activation, command registration, and scheduler bootstrap;
  both remain read-only and usable while admission is closed.
