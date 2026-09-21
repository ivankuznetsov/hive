# Command usage review validation

Completed U4's required local gates: changed-library coverage is 100% across
29 sources (6,039 executable lines; 2,177 tests / 14,076 assertions), and the
four-worker `bin/test --all` checkpoint passed across 838 files (14,172 tests /
287,669 assertions, zero failures/errors, 14 skips).

The focused selector now combines mirrored tests and exact require consumers.
Authored-workflow fixtures clean up their project registrations, Answer and
Module entry/error paths have behavioral coverage, and runtime transport
fixtures use explicit executables independent of host overrides. Static usage
declarations consistently pass explicit hashes, including both finding toggles
and the stage-action `pr` alias. [[cli]] now calls setup usage output versioned
`hive-setup.v1`; the earlier command-boundary fragment records lifecycle schema
widening and the completed local gates accurately.

See `docs/implementation/cli-usage-contracts-baseline.md` for commands, seeds,
reports, and the superseded incomplete attempts. Hosted CI remains pending in
[[gaps]].
