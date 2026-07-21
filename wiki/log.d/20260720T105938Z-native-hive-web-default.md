---
title: Make native Hive web the default
---

- `hive setup` now installs, starts, and truthfully probes the managed
  loopback Hive web service by default on supported Linux and macOS; users can
  opt out with `--no-service` or keep using bare `hive web` in the foreground.
- Setup and web JSON contracts separate installed, enabled, running, manager,
  URL, and readiness state, and loopback no-auth rejects untrusted Host values.
- Released managed web bundles resolve the installed `hive-cli` package root
  and are authenticated before extraction; custom remote URLs require an exact
  companion digest.
- Six canonical `HIVE_WEB_*` settings replace named native-web `HIVEBOX_*`
  aliases with next-major migration warnings, while container-only Hivebox
  variables remain canonical.
- Maintained Hive and OpenClaw guidance now leads with native Hive web and
  keeps Hivebox as the supported container path for isolation, multiple
  instances, untrusted-agent containment, and server/NAS deployment.
