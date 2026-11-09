# Default status consumes separate JSON boolean values

Startup route recognition now consumes Thor's supported separate JSON boolean
literals, so `hive status --json true` shares the one-second SQLite busy budget
and returns partial running status on exhaustion. Invalid and extra arguments
continue through ordinary CLI validation.

The shared `CliJsonOptions.requested?` detector also honors these values for
`--json`, `--no-json`, and `--skip-json`, preserving last-option precedence and
the `--` boundary. In particular, `--json false` selects human fallback output.

Regression coverage exercises all supported literal spellings and rejected
arguments in the existing unit tests. The real-lock integration case covers
both separate true and false values alongside ordinary human and JSON status.
