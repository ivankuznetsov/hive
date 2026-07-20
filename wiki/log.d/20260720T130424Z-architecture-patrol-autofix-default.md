# 2026-07-20 — Architecture patrol auto-fix by default

- Fresh terminal and web initialization now enable architecture-patrol
  discovery, confined auto-fix/PR attempts, and GitHub issue fallback together.
- Choosing `--no-refactor-patrol` or unchecking the setup choice writes all
  three gates off. Legacy projects without a `refactor_patrol` block remain
  inert, and older discovery-only configs do not silently inherit mutation or
  issue-filing authority.
