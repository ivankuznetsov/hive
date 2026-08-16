## 2026-08-16 — Cover the managed-runner fail-closed fallbacks

**Problem:** The Codex and Pi managed-runtime work in this branch added
fail-closed fallbacks that no test reached, so the exact-coverage gate rejected
`lib/hive/workflow_package/runtime_policy.rb` at 97.43% line coverage. Untested
fallbacks are exactly the paths that must not silently loosen isolation.

**Fix:** Extended `test/unit/workflow_package/runtime_policy_test.rb` with the
missing rejection and recovery paths: a malformed JSON fence alongside the real
managed payload, a path-qualified Codex `Read` whose target cannot be resolved,
Pi compilation without bubblewrap and without a readable auth file, and every
`pi_executable` outcome — the `mise which pi` fallback that resolves a managed
runtime, the unresolvable-candidate rejections, the bounded probe timeout, and a
missing `mise` binary.

**Verification:** `bundle exec ruby -Itest -Ilib
test/unit/workflow_package/runtime_policy_test.rb` passes and a scoped coverage
run reports no uncovered lines among the fourteen the merged gate flagged. See
[[modules/workflow_package]] and [[testing]].
