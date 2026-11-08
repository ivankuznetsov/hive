---
title: Native remote CLI transport
date: 2026-11-07
---

Registered context/token/operation commands with their consuming HTTPS
transport. Context configuration works before runtime activation on fresh
clients; remote commands retain a frozen installation target and never discover
the local checkout. Added explicit remote task content selectors/output,
write-only mutation spellings, fresh authority announcements, bounded verified
TLS, refused redirects, safe version guidance and honest lost-response keys.
Remote JSON DTO commands use the API envelope; operation lookup has its own
versioned CLI schema. Status project filters authorize before projection.

Focused TLS and executable tests cover transport faults, output order,
context-switch races, native argument compatibility and local checkout
isolation. Real server/daemon acceptance and deployment limits are documented
separately in [[remote-access]] and [[gaps]].
