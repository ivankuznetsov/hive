# Remove unused reserved occurrence view

- Removed `Patrol::StateStore#each_reserved_occurrence`, a public wrapper with
  no production caller.
- Scheduler coverage now loads the exact occurrence emitted in its dispatch,
  while restart authority remains covered through the production
  `each_recovery_active_occurrence` view.
