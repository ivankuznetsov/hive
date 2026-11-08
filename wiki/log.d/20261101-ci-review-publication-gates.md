## Review CI publication and security gates

- Replaced the full-pipeline scenario's placeholder PR URL with a valid local
  identity, scripted GitHub responses, and real Git publication over loopback.
- Added focused regression cases for all 22 lines reported missing by the CI
  coverage gate, covering review recovery, verification races, withheld
  publication, malformed evidence, closure diagnostics, and compact status UI.
- Updated both bundle lockfiles to Addressable 2.9.2 and SQLite3 2.10.2; both
  dependency audits pass against the current advisory database.
