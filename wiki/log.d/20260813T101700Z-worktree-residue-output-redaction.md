# Redact worktree recovery output paths

The agent-facing `hive worktree` status, commit-residue, and discard-residue
responses now redact secret-shaped path text in JSON, human-readable output,
and surfaced Git diagnostics. Recovery still operates on the exact raw paths
internally. This closes the remaining case where editing a legacy tracked file
whose name resembles a credential could auto-commit safely but expose that
name through the command response.
