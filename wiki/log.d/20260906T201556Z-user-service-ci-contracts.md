---
title: Preserve UserService packaging and launchd contracts
date: 2026-09-06
---

- Kept the public UserService entrypoint independent of the runtime control
  plane by loading task-lease storage only when task locking is used.
- Restored launchd install completion at the verified loaded-job boundary;
  command adapters continue to report inactive or unready processes as
  unhealthy without misreporting the plist mutation as failed.
- Updated the packaged setup fixture to implement the complete installer
  outcome interface.
