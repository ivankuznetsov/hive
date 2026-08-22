## OpenCode can own the unified Patrol Fix loop

- Added controller-owned OpenCode scopes for the built-in `patrol-fix`
  workflow instead of requiring a project-global permission override.
- Added one coherent `patrol.fix` identity block so repair can use OpenCode,
  an exact provider/model route, and a reasoning tier without changing either
  Patrol discovery engine.
- Documented that a mixed-provider setup narrows any coarse `models.patrol`
  route to `models.patrol_review`, preventing discovery model inheritance by
  the repair provider.
- Patrol review actors can write only their exact report and cannot run shell
  commands.
- Patrol fix actors can edit the owned worktree and exact report and receive
  the explicit `Bash(*)` grant required for reproduction, tests, and commits.
- Claude, Codex, Pi, Grok, and all non-Patrol stages retain their existing
  permission resolution.
