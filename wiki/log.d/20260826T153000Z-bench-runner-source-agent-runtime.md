# Seal the benchmark control bundle with its source-matched agent runtime

The benchmark runner image now builds and installs `agent-cli-runtime` from the
same exact Hive source archive before installing `hive-cli`. The image build
also verifies provider-error extraction and the OpenCode permission compiler.
This closes a build-time dependency-resolution gap where RubyGems selected the
older published 0.2.0 patch, causing Pi and OpenCode cells to fail before model
execution despite the source tree and lockfiles carrying 0.2.4.

The root-only control bundle includes the dependency. Candidate containers
cannot read Hive source or the control-bundle path; their separate bundle retains
shared dependency gems, including `agent-cli-runtime`.
