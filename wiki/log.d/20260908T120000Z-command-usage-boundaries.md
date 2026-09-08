# Command-owned usage contracts

Adapt the historical CliUsageContracts extraction to current main without the
removed circuits surface. Static declarations, variant selection, and custom
payload builders live in command boundary files. The shared module handles lazy
loading and generic envelope rendering. Lifecycle schemas now accept the existing
usage-error envelopes, including a separate closed publish usage arm. Schema versions, payloads, and exit codes are
unchanged.
Cold-load regressions run in fresh Ruby processes with inherited coverage boot.

The launcher now resolves once per rejected invocation and shares the identical
value with classification and emission. Resolution failures retain the neutral
human fallback and report only a bounded exception class on stderr, without retry.

U4 compatibility validation exposed existing workflow schema mismatches, resolved
by the schema compatibility follow-up. Review pass 01 completed U4: all 29
changed library files have exact 100% line coverage, and `bin/test --all` passed
with four workers. See `docs/implementation/cli-usage-contracts-baseline.md` for
the final counts and retained historical attempts.
