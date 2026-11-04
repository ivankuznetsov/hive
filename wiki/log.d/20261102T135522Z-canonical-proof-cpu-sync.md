# Synchronize canonical hosted-runner credential proof

Canonical commit `8d562e148902dfbfc9b32c4b333ce3d8593f31e3` on
`fix/profile-credential-isolation` in `tmp/bench-credential-canonical` now
overrides `HB_CPUS` to one in `test/isolation_proof_test.rb`, matching Hive's
`715cbeeeb7` fix. Its architecture/gaps pages and new log fragment document
the correction. The shared fake-Docker fixtures still request eight CPUs;
production defaults are unchanged. Both test trees were searched for the same
defect; no additional real-Docker credential proof needed the override.

Validation used a local Docker shim rejecting CPU requests above four while
forwarding other calls to Docker 29.9.2. The canonical proof before the fix
failed with exit 125. Afterward both `test:bench_isolation_proof` gates passed
with actual Bash 3.2.57 and 5.3.20 and all six real Docker credential probes:

- Canonical: 3 tests/40 assertions, with 15 tests/590 assertions per interpreter.
- Hive: 3 tests/55 assertions, with 15 tests/602 assertions per interpreter.
- Both: zero failures, errors or skips.

Full-file `cmp` checks pass for canonical and packaged `isolation.sh` and
`isolation_exec.rb`, preserving R6. Canonical RuboCop passes the changed proof
with its explicit owning config and parent exclusions disabled; the initial
invocation inherited Hive's unavailable Rails lint dependency. Both diffs pass
`git diff --check`. U4's delivery evidence and gaps now record the canonical
revision and this U3 proof. Subsequent Hive hosted confirmation is recorded in
`20261102T135954Z-bench-hosted-proof-confirmed.md`. Canonical publication is now
[hive-bench PR #16](https://github.com/ivankuznetsov/hive-bench/pull/16), at
`c1e5696944f590ea58985e174b8aff3409191f24`, including this CPU correction.
Canonical hosted checks and merge remain pending; the original dirty canonical
checkout is untouched.
