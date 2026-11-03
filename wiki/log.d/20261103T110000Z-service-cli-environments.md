## Read installed service execution environments

Added a read-only installed daemon/babysitter environment reader for systemd
and launchd. It preserves independent service PATHs and binary overrides,
reports incomplete reconstruction and stale running definitions explicitly,
and bounds filesystem inputs and manager metadata subprocesses. Fixture tests
cover both platforms without requiring a live manager.
