## Remove unused global-agent selection writer

- Removed `Config.write_global_agents!`, an unconnected module function whose
  only callers were its own unit tests; the setup executable never invoked it.
- Removed `normalize_global_agents` after the separately audited reader cleanup
  removed its final remaining caller.
- Removed the now-orphaned default-selection helper and constants after the
  reader, writer, and setup-prompt retirements.
- Retained coverage for the live registered-backend projection used by init.
