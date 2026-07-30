---
date: 2026-07-30
area: refactor-patrol, patrol, migration, packaging, security, recovery
---

# Close U2 install-wide migration and fingerprint predecessor gaps

- Defined the installation migration unit as every eligible OS user, every
  Hive profile bound to each identity, and every registered project in each
  profile. The real integration proof provisions three inactive users and
  migrates two projects per user across default, `HIVE_HOME`, and XDG layouts.
- Added one root-owned, locked, bounded, round-robin machine checkpoint so an
  hourly retry resumes later profiles without rewriting identical progress.
  Every sweep still re-enters every discovered profile; the child-owned live
  registry digest decides whether work is unchanged, so no root checkpoint row
  can suppress a project registered later by another user.
- Hardened the fixed root runtime, retry service, canonical profile roots,
  bounded discovery, and privilege-dropped child execution. Normal daemon
  startup remains admission-only; released-v2 conversion belongs only to the
  package candidate's install-wide sweep.
- Made `Hive::Patrol::StateStore` the sole ordinary effect-gateway composition
  root. Fingerprint mutations persist their exact set/delete operation, and a
  cycle recovers every active predecessor before any fingerprint read,
  dismissal, or suppression decision.
