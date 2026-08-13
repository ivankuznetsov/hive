# Remove unused module launch predicate

- Removed `Modules::ModuleDispatchResult#launched?`, which had no production
  caller.
- Retargeted module unit, integration, and E2E assertions to the authoritative
  persisted decision outcome while keeping attempt-admission checks intact.
