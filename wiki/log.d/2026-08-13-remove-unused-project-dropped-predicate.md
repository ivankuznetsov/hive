# Remove unused project-dropped predicate

- Removed `Daemon::ConcurrencyController#project_dropped?`, which had no
  production caller.
- Retargeted controller and dispatcher tests to the retained
  `dropped_projects` reporting collection while preserving admission and event
  assertions.
