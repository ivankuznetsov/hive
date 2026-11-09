# Publish canonical benchmark credential isolation (U4, review pass 03)

Canonical delivery is now durable at
[`c1e5696944f590ea58985e174b8aff3409191f24`](https://github.com/ivankuznetsov/hive-bench/commit/c1e5696944f590ea58985e174b8aff3409191f24),
on `fix/profile-credential-isolation-delivery`, through
[hive-bench PR #16](https://github.com/ivankuznetsov/hive-bench/pull/16).
`git ls-remote` and the PR API independently confirmed the same head. The PR
is open and targets `main`; publication is complete, while hosted checks and
merge remain pending. Its Ubuntu/macOS jobs started in
[CI run 41463576434](https://github.com/ivankuznetsov/hive-bench/actions/runs/41463576434).

The original clone's branch also contained unrelated unpublished benchmark
results. The delivery branch instead starts at current upstream
`243ef7bb7e2cb3f6ecbe2d5fe3f3ab9c83cff326` and ports only the five reviewed
credential commits (`dce0f155`, `a09fd659`, `7383c88b`, `f157ef79`, `8d562e14`).
The result changes 19 files: the original credential-change set plus a delivery
log fragment. The two runtime files match Hive's packaged copies byte-for-byte;
the v2 runtime and unrelated upstream files remain unchanged. All local writes
are inside this Hive worktree, including `tmp/bench-credential-delivery`;
the original dirty canonical checkout remains untouched.

Fresh validation on the canonical delivery branch:

- `bundle exec rake test`: 361 tests/1900 assertions, no failures/errors/skips.
- `test:bench_isolation_proof` with actual Bash 3.2.57/5.3.20 and Docker 29.9.2:
  3 tests/40 assertions, no failures/errors/skips. Each interpreter's nested
  matrix passes 15 tests/590 assertions; all six real decoy probes pass using
  the existing pinned Alpine image and separate `sh -c` argv.
- Owning RuboCop: seven files, no offenses, using its explicit config and
  `--ignore-parent-exclusion`. ShellCheck 0.11.0 and whitespace checks pass.
- Full-file `cmp` passes for delivered and packaged `isolation.sh` and
  `isolation_exec.rb`.
- Hive's focused executor, shell and workflow-install regressions also pass:
  19 tests/661 assertions, no failures/errors/skips.

Fixtures use an in-worktree `TMPDIR` and matching `GIT_CEILING_DIRECTORIES`.
Without the ceiling, the first broad run's residue-recovery test discovers the
enclosing Hive repository after removing its fixture `.git` and fails (expected
exit 5, actual 0). The bounded full rerun passes without code changes. This is
separate from the successful credential proofs.

Updated the U4 evidence table, current gaps, and both follow-up fragments that
still described canonical publication as pending. No Hive product code changed.
