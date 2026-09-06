---
title: Close UserService activation and teardown races
date: 2026-09-06
---

- Bound restart replay to the process identity observed after the desired
  systemd definition was reloaded, preventing an old cached definition's
  automatic restart from satisfying activation.
- Kept apply and rollback replay files unchanged while their recorded manager
  is unavailable, and treated a deactivating unit with a live main process as
  not yet stopped.
- Moved uninstall foreground-process stops under canonical target ownership
  and carried actionable contention and recovery guidance through lifecycle
  CLI errors, including the Web adapter.
