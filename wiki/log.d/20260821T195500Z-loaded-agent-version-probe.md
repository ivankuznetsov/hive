# Tolerate loaded agent CLI startup in version probes

- Raised Agent CLI Runtime's bounded local version/help capture deadline from
  ten to thirty seconds.
- Parallel Ox Alpha cells reproduced a false Pi preflight failure when two
  containers started under heavy swap pressure and `pi --version` exceeded the
  ten-second deadline; the provider was never called.
- Process-group termination, bounded capture, version parsing, and per-route
  cache behavior remain unchanged.
