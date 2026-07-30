---
date: 2026-07-30
area: refactor-patrol, migration, packaging, security, recovery
---

# Make legacy JobStore conversion explicitly install-wide and v3-only at runtime

- Removed constructor and normal-CLI conversion paths: released-v2 JobStores
  now migrate only through the explicit package-candidate command, and every
  normal JobStore consumer admits v3 only.
- Hardened the root coordinator to cover every discovered OS user's Hive
  profiles and every project registered in those profiles. Discovery uses a
  bounded NSS snapshot; execution revalidates canonical roots, uid, gid, and
  supplementary groups before dropping identity.
- Added mutation-free preflight for shared state-root collisions, while exact
  duplicate registrations convert once and receive the same result.
- Added root-owned systemd and launchd hourly retry installation for direct
  packages and root bash updates. Homebrew and other user-prefix installs stay
  unprivileged and must never be elevated.
- Routed ordinary patrol fingerprint state through its mandatory effect
  gateway and made daemon restart completion wait for a daemon-owned readiness
  acknowledgement.
