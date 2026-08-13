## Remove unused global-agent selection writer

- Removed `Config.write_global_agents!`, an unconnected module function whose
  only callers were its own unit tests; the setup executable never invoked it.
- Removed `normalize_global_agents` after the separately audited reader cleanup
  removed its final remaining caller.
- Retained coverage for the live setup prompt, canonical defaults, and
  registered-backend projection.
