## Patrol Fix actor routing

- Restored independent `patrol.agent` and `models.patrol_review` routing for
  Patrol Fix inbox and review adjudication.
- Reserved `patrol.fix.agent` and `models.patrol_fix` for admitted repair work,
  so choosing OpenCode/Ox Alpha as the fix agent no longer moves semantic
  admission onto that provider.
- Added focused coverage for distinct review and fix agents.
