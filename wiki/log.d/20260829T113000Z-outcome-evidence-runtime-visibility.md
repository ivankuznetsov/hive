# Outcome evidence keeps its issued Ruby runtime visible

**Why:** A Codex evidence producer could receive an exact `RbConfig.ruby`
capture prefix while the closed filesystem policy hid that executable. Env
shebangs then fell through to the system Ruby, project dependencies appeared
missing, and raw source-checkout terminal capture failed because the
source-loaded `agent-cli-runtime` had no activated RubyGems specification.

**Change:** Admit the controller's exact Ruby executable, binstubs, runtime
libraries, and active gem paths to the producer's read-only policy. Terminal
custody now resolves `agent-cli-runtime` from the activated gem or the exact
loaded feature path. The producer prompt keeps package installation and package
registries outside the evidence boundary.

**Verification:** Focused capture-toolkit and terminal-recorder tests cover the
runtime policy and the no-activated-spec source-checkout path.
