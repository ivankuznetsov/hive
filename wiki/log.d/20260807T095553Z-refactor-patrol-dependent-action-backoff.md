## Architecture Patrol respects dependent action cooldowns

- Made Architecture Patrol job admission treat a same-family or same-thesis issue as dependent on its nonterminal fix.
- Prevented queued issue actions from bypassing the fix action's one-hour retry backoff and relaunching an action child every daemon tick.
- Added a regression covering the mixed fix-and-issue job observed during local dogfooding.
