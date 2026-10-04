# 2026-10-02 — Project owns the stable workflow view

- `Hive::Workflows::Project.with_active_workflows` now activates one project's
  accepted descriptors and holds the existing reentrant Monitor through live
  Registry and stage-vocabulary reads. Same-root nesting is supported; a
  different-root nested activation is rejected before registry mutation.
- Workflow selection, config validation, task resolution, status and dependency
  generations, digest reporting, daemon helpers, and Web models now resolve
  project-dependent workflow data inside that operation or consume bounded data
  captured there.
- An executable occurrence-level reader inventory is mirrored in the workflow
  wiki so new or duplicated live Registry and workflow-union reads require an
  explicit safety classification.
