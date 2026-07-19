## 2026-07-18 — Share implementation identity event assembly

- Added `Hive::ImplementationIdentity::EventBuilder` for the identical durable
  journal envelope used by live identity capture and legacy reconstruction.
- Kept generation/selection policy in `Store` and recovery policy in
  `Reconstructor` while centralizing attempt lookup, coding-stage identity,
  generations, lease evidence, provenance, and payload shape.
- Verified capture, reconstruction, journal, and routing behavior together: 31
  runs, 130 assertions, zero failures, zero errors, and zero skips.
