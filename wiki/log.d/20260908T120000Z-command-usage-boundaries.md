# Command-owned usage contracts

Adapt the historical CliUsageContracts extraction to current main without the
removed circuits surface. Static declarations, variant selection, and custom
payload builders live in command boundary files. The shared module handles lazy
loading and generic envelope rendering. No public schema or exit code changes.
Cold-load regressions run in fresh Ruby processes with inherited coverage boot.
