# Preserve managed runner timeout errors during capture cleanup

- Managed runner provenance probes now preserve their primary `Timeout::Error`
  when closing stdout or stderr wakes a capture reader with `IOError`.
- The runtime-policy test suite now deterministically covers Grok's
  fail-closed behavior when bubblewrap is unavailable.
