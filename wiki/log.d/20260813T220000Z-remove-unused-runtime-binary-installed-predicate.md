## Remove unused runtime override binary predicate

- Removed `AgentProfile::RuntimeProfileOverride#binary_installed?`, whose only
  callers were direct unit assertions. Hive runtime code does not probe the
  compatibility override through this predicate.
- Retained the override's binary, version, and CLI-capability preflight
  assertions. They now prove the inherited `agent-cli-runtime` probe respects
  Hive's overridden executable selection and fail-soft behavior.
