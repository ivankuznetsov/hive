## Remove unused global-agent selection writer

- Removed `Config.write_global_agents!`, an unconnected module function whose
  only callers were its own unit tests; the setup executable never invoked it.
- Retained global-agent reader normalization coverage, including canonical
  ordering, validation, defaults, and registered-backend checks.
