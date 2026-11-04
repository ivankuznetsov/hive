# Confirm hosted benchmark credential isolation evidence

Both `bench credential isolation` lanes passed on `ubuntu-24.04` and
`macos-15` in
[CI run 41454797098](https://github.com/ivankuznetsov/hive/actions/runs/41454797098)
at `715cbeeeb72ce15e51278a155e40a4c43f6b51d8`. Only wiki documents changed
between that tested commit and the reviewed HEAD. The current gap and U4
acceptance table now link this result, including confirmation of the one-CPU
Docker proof correction.

This supersedes the pending hosted-confirmation statements in
`20261102T102000Z-bench-isolation-proof.md`,
`20261102T135522Z-canonical-proof-cpu-sync.md`, and
`20261102T140000Z-bench-proof-cpu-limit.md`; those entries retain the earlier
local-proof history. Canonical upstream publication was subsequently completed
in [hive-bench PR #16](https://github.com/ivankuznetsov/hive-bench/pull/16), at
`c1e5696944f590ea58985e174b8aff3409191f24`. Its hosted checks and merge remain
separate from Hive's successful hosted proof.
