# Hive consumes agent-cli-runtime 0.2.x

**Action:** Narrowed Hive's runtime dependency from the temporary release-prep
window to `agent-cli-runtime ~> 0.2.0` after the protected component workflow
published the retained candidate, Linux and macOS install jobs passed, and an
independent RubyGems fetch matched SHA-256
`b813b54d0dded7ecab2a7aa569d997c7d4c24666b76ba675196cb30e10e08320`.

**Compatibility:** Fresh isolated installation reported version 0.2.0 and a
ready OpenCode 1.18.18 JSON probe with the expected 1.18.16 minimum and
declared capabilities. The immutable mirror release `v0.2.0` records canonical
Hive commit `c8f62cacefb9d5982ab0e8d2328071763b3736c4` and publishes the matching
OpenCode changelog highlights.

**Boundary:** This changes Hive's consumer requirement only. It does not bump,
tag, publish, or deploy Hive.
